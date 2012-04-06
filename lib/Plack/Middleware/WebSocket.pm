package Plack::Middleware::WebSocket;
use strict;
use warnings;
use parent 'Plack::Middleware';

use Digest::SHA1 qw();
use MIME::Base64 qw();

our $VERSION = '0.01';

sub call {
    my ($self, $env) = @_;

    $env->{'websocket.impl'} = Plack::Middleware::WebSocket::Impl->new($env);

    return $self->app->($env);
}

package Plack::Middleware::WebSocket::Impl;
use Plack::Util::Accessor qw(env error_code);
use Digest::MD5 qw(md5);
use Scalar::Util qw(weaken);
use IO::Handle;

sub new {
    my ($class, $env) = @_;
    my $self = bless { env => $env }, $class;
    weaken $self->{env};
    return $self;
}

sub handshake {
    my ($self, $respond) = @_;

    my $env = $self->env;

    my %http_conn = map{ ( lc( $_ ), 1 ) } split ( / *, */, $env->{'HTTP_CONNECTION'} );
    my %http_upgr = map{ ( lc( $_ ), 1 ) } split ( / *, */, $env->{'HTTP_UPGRADE'} );
    unless ( $http_conn{'upgrade'} && $http_upgr{'websocket'} ) {
        $self->error_code(401);
        return;
    }

    my $fh = $env->{'psgix.io'};
    unless ($fh) {
        $self->error_code(501);
        return;
    }

    my $digest;
    {
        my $key = $env->{'HTTP_SEC_WEBSOCKET_KEY'};
        my $kk  = $key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
        $digest = MIME::Base64::encode_base64( Digest::SHA1::sha1( $kk ) );
        # これでよい? ($digest の末尾に改行文字 (?) が含まれているのはなぜか)
        chomp $digest;
    }

    $fh->autoflush;

#    return [
#        'Upgrade'             , 'websocket',
#        'Connection'          , 'Upgrade'  ,
#        'Sec-WebSocket-Accept', $digest    ,
#    ];

    print $fh join "\015\012", (
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Accept: ' . $digest,
        '',
        '',
    );

    return $fh;
}

1;

__END__

=head1 NAME

Plack::Middleware::WebSocket - Support WebSocket implementation

=head1 SYNOPSIS

  builder {
      enable 'WebSocket';
      sub {
          my $env = shift;
          ...
          if (my $fh = $env->{'websocket.impl'}->handshake) {
              # interact via $fh
              ...
          } else {
              $res->code($env->{'websocket.impl'}->error_code);
          }
      };
  };


=head1 DESCRIPTION

Plack::Middleware::WebSocket provides WebSocket implementation through $env->{'websocket.impl'}.
Currently implements RFC 6455 <http://tools.ietf.org/html/rfc6455>.

=head1 METHODS

=over 4

=item my $fh = $env->{'websocket.impl'}->handshake;

Starts WebSocket handshake and returns filehandle on successful handshake.
If failed, $env->{'websocket.impl'}->error_code is set to an HTTP code.

=back

=head1 Secure WebSockets (wss://)

If you are using this middleware behind an SSL HTTP proxy, like STunnel, you should
use L<Plack::Middleware::ReverseProxy>. If you do not use the ReverseProxy
middleware you will get handshake mismatch errors on the client.

  builder {
    enable_if { $_[0]->{REMOTE_ADDR} eq '127.0.0.1' } 
              "Plack::Middleware::ReverseProxy";
    enable "WebSocket";
    $app; 
  };

=head1 AUTHOR

motemen E<lt>motemen@gmail.comE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
