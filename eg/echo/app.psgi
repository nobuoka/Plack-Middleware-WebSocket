#!perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Plack::Builder;
use Plack::Request;
use AnyEvent;
use AnyEvent::Handle;
use WebSocket::ServerAgent;

my $DATA = do { local $/; scalar <DATA> };

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $res = $req->new_response(200);

    if (not $env->{'psgi.streaming'}) {
        die 'this handler does not support psgi.streaming';
    }

    if ($req->path eq '/') {
        my $data = $DATA;
        $data =~ s/{{{HOST}}}/$env->{HTTP_HOST}/g;
        $res->content_type('text/html; charset=utf-8');
        $res->content($data);
    }
    elsif ($req->path eq '/echo') {
        if ( my $fh = $env->{'websocket.impl'}->handshake ) {
            return start_ws_echo( $fh );
        }
        $res->code($env->{'websocket.impl'}->error_code);
    }
    else {
        $res->code(404);
    }

    return $res->finalize;
};

sub start_ws_echo {
    my ($fh) = @_;

    my $agent = WebSocket::ServerAgent->new( $fh );
    return sub {
        my $respond = shift;
        $agent->onclose( sub {
            warn '[DEBUG] on close!!!';
            # 循環参照を断つ
            undef $agent;
        } );
        $agent->onmessage( sub {
            my ( $message ) = @_;
            warn '[DEBUG] on message: ' . $message;

            # echo (delay)
            my $w; $w = AE::timer 1, 0, sub {
                $agent->send_text( $message );
                undef $w;
            };

            # close if message is 'close'
            if ( $message eq 'close' ) {
                warn '[DEBUG] to be closed...';
                $agent->close();
            }
        } );
        return;
    };
}

builder {
    enable 'WebSocket';
    $app;
};

__DATA__
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title>Plack::Middleware::WebSocket</title>
    <script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.4.2/jquery.min.js"></script>
    <style type="text/css">
#log {
  border: 1px solid #DDD;
  padding: 0.5em;
}
    </style>
  </head>
  <body>
    <script type="text/javascript">
function log (msg) {
  $('#log').text($('#log').text() + msg + "\n");
}

$(function () {
  var ws = new WebSocket('ws://{{{HOST}}}/echo');

  log('WebSocket start');

  ws.onopen = function () {
    log('connected');
  };

  ws.onmessage = function (ev) {
    log('received: ' + ev.data);
  };

  ws.onerror = function (ev) {
    log('error: ' + ev.data);
  }

  ws.onclose = function (ev) {
    log('closed');
  }

  $('#form').submit(function () {
    var data = $('#message').val();
    ws.send(data);
    $('#message').val('');
    log('sent: ' + data);
    return false;
  });
});
    </script>
    <form id="form">
      <input type="text" name="message" id="message" />
      <input type="submit" />
    </form>
    <pre id="log"></pre>
  </body>
</html>
