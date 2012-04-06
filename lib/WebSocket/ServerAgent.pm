package WebSocket::ServerAgent;
use strict;
use warnings;
use utf8;

use Encode;
use AnyEvent::Handle;
use Scalar::Util qw( weaken );

# ---------------
#  class methods 
# ---------------

# ソケットを表す IO を受け取って, その IO を用いた入出力を行う
# ハンドシェイクは終わっていること
sub new {
    my $class = shift;
    my ( $sock ) = @_;

    my $self = bless {}, $class;

    # 循環参照を断つ
    # 実際には eof で undef して切るのが良い?
    weaken( my $weaken_self = $self );
    my $handle = AnyEvent::Handle->new( fh => $sock );
    $handle->on_read( sub { _read( $weaken_self, @_ ) } );
    $handle->on_eof ( sub { _eof ( $weaken_self, @_ ) } );

    $self->{handle} = $handle;
    $self->{already_send_close_frame} = !!1;
    return $self;
}

# ------------------
#  instance methods 
# ------------------

sub send_text {
    my $self = shift;
    my ( $data ) = @_;

    $data = Encode::encode_utf8( $data );
    # 長さの取得
    my $len = length( $data );
    my $ext_len = undef;
    if ( $len < 126 ) {
        # ok
    }
    else {
        if ( $len < 0x8000 ) { # 2 byte で収まる? (MSB MUST BE ZERO)
            $ext_len = pack( 'n', $len );
            $len = 126;
        }
        elsif ( $len < 0x80000000 ) { # 4 byte?
            $ext_len = pack( 'N', $len );
            $len = 127;
        }
        else {
            # TODO
            die 'too large';
        }
    }

    my $bytes = '';
    # 最初の 2 バイト
    $bytes .= pack( 'C', 0x81 );
    $bytes .= pack( 'C', $len );
    # ext length (if exist)
    if ( $ext_len ) {
        $bytes .= $ext_len;
    }
    $bytes .= $data; # payload data

    $self->{handle}->push_write( $bytes );
}

sub send_binary {
    my $self = shift;
    my ( $data ) = @_;

    die 'not implemented yet';
}

sub close {
    my $self = shift;
    $self->_send_close_frame();
}

sub onmessage {
    my $self = shift;
    my ( $cb ) = @_;
    if ( $cb ) {
        return $self->{onmessage_cb} = $cb;
    } else {
        return $self->{onmessage_cb};
    }
}

sub onerror {
    my $self = shift;
    warn 'on error';
}

sub onclose {
    my $self = shift;
    my ( $cb ) = @_;
    if ( $cb ) {
        return $self->{onclose_cb} = $cb;
    } else {
        return $self->{onclose_cb};
    }
}

sub _send_close_frame {
    my $self = shift;

    # TODO 既に送っている場合は...?
    if ( $self->{already_send_close_frame} ) {
        return;
    }

    # 長さの取得
    my $len = 0; #length( $data );
    my $ext_len = undef;
    if ( $len < 126 ) {
        # ok
    }
    else {
        if ( $len < 0x8000 ) { # 2 byte で収まる? (MSB MUST BE ZERO)
            $ext_len = pack( 'n', $len );
            $len = 126;
        }
        elsif ( $len < 0x80000000 ) { # 4 byte?
            $ext_len = pack( 'N', $len );
            $len = 127;
        }
        else {
            # TODO
            die 'too large';
        }
    }

    my $bytes = '';
    # 最初の 2 バイト
    $bytes .= pack( 'C', 0x88 );
    $bytes .= pack( 'C', $len );
    # ext length (if exist)
    if ( $ext_len ) {
        $bytes .= $ext_len;
    }
    #$bytes .= $data; # payload data

    $self->{handle}->push_write( $bytes );
    $self->{already_send_close_frame} = 1;
}

# フレームが送られてきたらとりあえずここにくる
# fragmented なフレームの場合, 次のフレームを待つ
# non-fragmented なフレームの場合, onmessage に行く
sub _receive_frame {
    my $self = shift;
    my ( $frame ) = @_;

    # control frames
    if ( 0x08 <= $frame->{opcode} ) {
        # RFC 6455, 5.4
        # control frames MUST NOT be fragmented
        # control frames MAY be injected in the middle of a fragmented message
        # TODO

        # Close frame
        if ( $frame->{opcode} == 0x08 ) {
            # まだ close フレームを送っていない場合は送る
            if ( not $self->{already_send_close_frame} ) {
                $self->_send_close_frame();
            }
            # ソケットを閉じる
            $self->{handle}->push_shutdown();
        }
    }
    # message frames
    else {
        if ( $frame->{fin} && ( $frame->{opcode} == 1 || $frame->{opcode} == 2 ) ) {
            $self->_do_onmessage( $frame->{appdat} );
        } else {
            # TODO
            die 'not implemented yet';
        }
    }
}

#
# frame = {
#     fin    => 真偽値,
#     rsv1   => 真偽値,
#     rsv2   => 真偽値,
#     rsv3   => 真偽値,
#     opcode => int,
#     extdat => unknown,
#     appdat => utf8 string or binary string, 
# }
# binary string は utf8::is_utf8( $str ) が偽になるような $str ってことでいいの?

#====================
# internal functions 
#====================

# callback
sub _read {
    my $agent = shift;
    my $frame = {};
    my ( $handle ) = @_;

    $handle->unshift_read( chunk => 2, sub { _read_normal_header( $agent, $frame, @_ ) } );
}

# callback
sub _read_normal_header {
    my $agent = shift;
    my $frame = shift;
    my ( $handle, $buf ) = @_;

    # buf を読んで, fragmentation の有無や長さ, Text か Binary かその他かをチェック
    my ( $b1, $b2 ) = unpack( 'CC', $buf );
    $frame->{fin}    = !!( $b1 & 0x80 );
    $frame->{rsv1}   = !!( $b1 & 0x40 );
    $frame->{rsv2}   = !!( $b1 & 0x20 );
    $frame->{rsv3}   = !!( $b1 & 0x10 );
    $frame->{opcode} = $b1 & 0x0F;
    my $mask         = !!( $b2 & 0x80 );
    my $paylen       = $b2 & 0x7F;

    # TODO エラー通知とか
    if ( not $mask ) {
        warn 'error';
        die 'client must mask the data' unless $mask;
    }

    # multibyte のバイトオーダーはネットワークオーダー
    if ( $paylen == 126 ) { # 続く 2 バイトが長さ
        my $len = 2;
        $handle->unshift_read( chunk => $len,
            sub { _read_ext_payload_length( $agent, $frame, @_ ) } );
    }
    elsif ( $paylen == 127 ) { # 続く 4 バイトが長さ
        my $len = 4;
        $handle->unshift_read( chunk => $len,
            sub { _read_ext_payload_length( $agent, $frame, @_ ) } );
    }
    else {
        my $len = 4 + $paylen;
        $handle->unshift_read( chunk => $len, sub { _read_payload( $agent, $frame, @_ ) } );
    }
}

sub _read_ext_payload_length {
    my $agent = shift;
    my $frame = shift;
    my ( $handle, $buf ) = @_;

    my $paylen = unpack( ( length $buf ) == 2 ? 'n' : 'N', $buf ); # n: 16-bit, N: 32-bit unsigned
    my $len = 4 + $paylen;
    $handle->unshift_read( chunk => $len, sub { _read_payload( $agent, $frame, @_ ) } );
}

# callback
sub _read_payload {
    my $agent = shift;
    my $frame = shift;
    my ( $handle, $buf ) = @_;

    # unmask (RFC 6455, 5.3)
    my $masking_key = substr( $buf, 0, 4 );
    my $masked_data = substr( $buf, 4    );
    my @unmasked_bytes;
    my @key_bytes = unpack( 'C4', $masking_key );
    my $i = 0;
    for ( unpack( 'C*', $masked_data ) ) {
        push( @unmasked_bytes, $_ ^ $key_bytes[$i] );
        ( ++ $i ) < 4 or $i = 0;
    }
    my $ss = pack( 'C*', @unmasked_bytes );

    # テキストの場合, UTF-8 として扱う
    if ( $frame->{opcode} == 0x01 ) {
        $ss = Encode::decode_utf8( $ss );
    }
    # TODO invalid な UTF-8 でないかどうか
    # TODO binary の場合は?

    $frame->{appdat} = $ss;
    $agent->_receive_frame( $frame );
}

sub _error {
    # TODO implement
}

sub _eof {
    my $self = shift;
    my ( $handle ) = @_;
    $self->_do_onclose();
}

#---------------------
# event handler の実行
#---------------------

sub _do_onclose {
    my $self = shift;
    my $cb = $self->{onclose_cb};
    $cb->() if ( $cb );
}

sub _do_onmessage {
    my $self = shift;
    my ( $message ) = @_;
    my $cb = $self->{onmessage_cb};
    $cb->( $message ) if ( $cb );
}

sub DESTROY {
    my $self = shift;
    warn '[DEBUG] DESTROY!!!!!';
}

1;
