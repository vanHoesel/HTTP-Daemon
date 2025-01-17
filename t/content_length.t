use strict;
use warnings;

use Test::More 0.98;

use Config;

use HTTP::Daemon;
use HTTP::Response;
use HTTP::Status;
use HTTP::Tiny 0.042;

patch_http_tiny(); # do not fix Content-Length, we want to forge something bad

plan skip_all => "This system cannot fork" unless can_fork();

my $BASE_URL;
my @TESTS = get_tests();

for my $test (@TESTS) {

    my $http_daemon = HTTP::Daemon->new() or die "HTTP::Daemon->new: $!";
    $BASE_URL = $http_daemon->url;

    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ($pid == 0) {
        accept_requests($http_daemon);
    }

    my $resp = http_test_request($test);

    ok $resp, $test->{title};

    is $resp->{status}, $test->{status},
        "... and has expected status";

    like $resp->{content}, $test->{like},
        "... and body does match"
        if $test->{like};

}

done_testing;



sub get_tests{
    {
        title   => "Hello World Request ... it works as expected",
        path    => "hello-world",
        status  => 200,
        like    => qr/^Hello World$/,
    },
    {
        title   => "Positive Content Length",
        method  => "POST",
        body    => "ABCDEFGH",
        headers => {
            'Content-Length' => '+6', # quotes are needed to retain plus-sign
        },
        status  => 400,
        like    => qr/value must be an unsigned integer/,
    },
    {
        title   => "Negative Content Length",
        method  => "POST",
        body    => "ABCDEFGH",
        headers => {
            'Content-Length' => '-5',
        },
        status  => 400,
        like    => qr/value must be an unsigned integer/,
    },
    {
        title   => "Non Integer Content Length",
        method  => "POST",
        body    => "ABCDEFGH",
        headers => {
            'Content-Length' => '3.14',
        },
        status  => 400,
        like    => qr/value must be an unsigned integer/,
    },
    {
        title   => "Explicit Content Length ... with exact length",
        method  => "POST",
        headers => {
            'Content-Length' => '8',
        },
        body    => "ABCDEFGH",
        status  => 200,
        like    => qr/^ABCDEFGH$/,
    },
    {
        title   => "Implicit Content Length ... will always pass",
        method  => "POST",
        body    => "ABCDEFGH",
        status  => 200,
        like    => qr/^ABCDEFGH$/,
    },
    {
        title   => "Shorter Content Length ... gets truncated",
        method  => "POST",
        headers => {
            'Content-Length' => '4',
        },
        body    => "ABCDEFGH",
        status  => 200,
        like    => qr/^ABCD$/,
    },
    {
        title   => "Different Content Length ... must fail",
        method  => "POST",
        headers => {
            'Content-Length' => ['8', '4'],
        },
        body    => "ABCDEFGH",
        status  => 400,
        like    => qr/values are not the same/,
    },
    {
        title   => "Underscore Content Length ... must match",
        method  => "POST",
        headers => {
            'Content_Length' => '4',
        },
        body    => "ABCDEFGH",
        status  => 400,
        like    => qr/values are not the same/,
    },
    {
        title   => "Longer Content Length ... gets timeout",
        method  => "POST",
        headers => {
            'Content-Length' => '9',
        },
        body    => "ABCDEFGH",
        status  => 599, # silly code !!!
        like    => qr/^Timeout/,
    },

}



sub router_table {
    {
        '/hello-world' => {
            'GET' => sub {
                my $resp = HTTP::Response->new(200);
                $resp->content('Hello World');
                return $resp;
            },
        },

        '/' => {
            'POST' => sub {
                my $rqst = shift;

                my $body = $rqst->content();

                my $resp = HTTP::Response->new(200);
                $resp->content($body);

                return $resp
            },
        },
    }
}



sub can_fork {
    $Config{d_fork} || (($^O eq 'MSWin32' || $^O eq 'NetWare')
    and $Config{useithreads}
    and $Config{ccflags} =~ /-DPERL_IMPLICIT_SYS/);
}



# run the mini HTTP dispatcher that can handle various routes / methods
sub accept_requests{
    my $http_daemon = shift;
    while (my $conn = $http_daemon->accept) {
        while (my $rqst = $conn->get_request) {
            if (my $resp = dispatch_request($rqst)) {
                $conn->send_response($resp);
            }
        }
        $conn->close;
        undef($conn);
        $http_daemon->close;
        exit 1;
    }
}



sub dispatch_request{
    my $rqst = shift
        or return;
    my $path = $rqst->uri->path
        or return;
    my $meth = $rqst->method
        or return;
    my $code =  router_table()->{$path}{$meth}
        or return HTTP::Response->new(RC_NOT_FOUND);
    my $resp = $code->($rqst);
    return $resp;
}



sub http_test_request {
    my $test = shift;
    my $http_client = HTTP::Tiny->new(
        timeout => 5,
        proxy => undef,
        http_proxy => undef,
        https_proxy => undef,
    );
    my $resp;
    eval {
        local $SIG{ALRM} = sub { die "Timeout\n" };
        alarm 2;
        $resp = $http_client->request(
            $test->{method} || "GET",
            $BASE_URL . ($test->{path} || ""),
            {
                headers => $test->{headers},
                content => $test->{body}
            },
        );
    };
    my $err = $@;
    alarm 0;
    diag $err if $err;

    return $resp
}



sub patch_http_tiny {

    # we need to patch write_content_body
    # this is part of HTTP::Tiny internal module HTTP::Tiny::Handle
    #
    # the below code is from the original HTTP::Tiny module, where just two lines
    # have been commented out

    no strict 'refs';
    no warnings;

    *HTTP::Tiny::Handle::write_content_body = sub {
        @_ == 2 || die(q/Usage: $handle->write_content_body(request)/ . "\n");
        my ($self, $request) = @_;

        my ($len, $content_length) = (0, $request->{headers}{'content-length'});
        while () {
            my $data = $request->{cb}->();

            defined $data && length $data
                or last;

            if ( $] ge '5.008' ) {
                utf8::downgrade($data, 1)
                    or die(qq/Wide character in write_content()\n/);
            }

            $len += $self->write($data);
        }

#       this should not be checked during our tests, we want to forge bad requests
#
#       $len == $content_length
#           or die(qq/Content-Length mismatch (got: $len expected: $content_length)\n/);

        return $len;
    };
}
