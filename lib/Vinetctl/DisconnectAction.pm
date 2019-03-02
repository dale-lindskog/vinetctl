package Vinetctl::DisconnectAction;

# Copyright (c) 2019 Dale Lindskog <dale.lindskog@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use feature qw( say );
use constant { TRUE => 1, FALSE => 0 };

use Vinetctl::Globals qw( 
    %args 
    %rc 
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
);

use Vinetctl::Tmux qw(
    tmux_has_session
    tmux_cmd
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    disconnect_action
);

# disconnect_action(): remotely disconnect from topology's tmux session
########################################################################

sub disconnect_action {
    report_calling_stack(@_) if $args{d};

    $globals{top_owner} ne $rc{username}
        or Die "'disconnect' only valid with -u\n";

    my $uid = ( getpwnam($rc{username}) )[2] 
        or Die "getpwnam() failed for $rc{username}: $!\n";

    my $sock = 
        "/tmp/$rc{progname}-${uid}-$globals{topology_name}";
    my $target_session = 
        "${globals{topology_name}}%${args{u}}~$rc{username}";

    if ( not tmux_has_session($sock, $target_session) ) {
        say "$target_session doesn't exist";
    } 
    else { # session exists: kill it
        tmux_cmd( $sock, $target_session, 'kill-session' );
        say "ok";
    }

    return( report_retval() );
}

1;
