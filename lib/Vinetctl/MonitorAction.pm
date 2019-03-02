package Vinetctl::MonitorAction;

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
use File::Basename qw( basename );
use File::Temp qw( tempfile );

use Vinetctl::Globals qw( 
    %args 
    %rc 
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
    Warn
);

use Vinetctl::Util qw(
    my_system
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Vinetctl::Topology qw(
    get_vmref_by_name
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    monitor_action
);

# monitor_action(): connect to managment socket of vm, vde, or wirefilter
##########################################################################

sub monitor_action {
    report_calling_stack(@_) if $args{d};

    my @monitor_params = @{ $globals{monitor_params} };

    unless ( @monitor_params == 1 ) {
        Die "usage: $rc{progname} [-f TOPOLOGY ] ", 
            "$globals{action_name} SOCKET\n";
    }

    my $monitor_param = $monitor_params[0];
    my $component;  # vm, vde switch, wirefilter?

    # figure out what user wants to monitor
    ########################################

    if ( $monitor_param =~ m/\./ ) { 
        # vde or wirefilter
        if ( $monitor_param !~ m/--/ ) { 
            # vde switch 
            $component = 'vde';
        } 
        else { 
            # wirefilter
            $component = 'wirefilter';
        } 
    } 
    else { 
        # qemu vm 
        $component = 'vm' 
    } 

    # connect to mgmt socket of specified component
    ################################################

    my $sock;
    if ( $component eq 'vm' ) {
        unless ( get_vm_status(get_vmref_by_name($monitor_param)) ) {
            my $msg = "$monitor_param is down\n";
            if ( $globals{dialog_loop} ) { print $msg; return }
            else                         { Die "$monitor_param is down\n" }
        }
        $sock = join( '/', 
                       $rc{socket_dir}, 
                       $globals{topology_name}, 
                       $monitor_param           );
    } 
    elsif ( $component eq 'vde' ) {
        $sock = join( '/', 
                       $rc{vde_dir}, 
                       $globals{topology_name}, 
                      "$monitor_param.mgmt"     );
    } 
    elsif ( $component eq 'wirefilter' ) {
        $sock = join( '/', 
                       $rc{wirefilter_dir}, 
                       $globals{topology_name}, 
                      "$monitor_param.mgmt"     );
    } 
    else { Die "bad parameter: $monitor_param\n" }

    -e $sock 
        or Die "monitor socket", basename($sock), "doesn't exist\n";
    -S _  
        or Die "monitor socket", basename($sock), "not a socket!\n";

    my $cmd = ( -e $rc{socat} ? "$rc{socat} - UNIX-CONNECT:" :
                                "$rc{unixterm} " )
                              . $sock;

    # we unlink pid file since we won't run exit handler at END of vinetctl
    unlink $globals{pid_file}
        or Warn "cannot unlink $globals{pid_file}: $!\n";

    exec $cmd or Die "couldn't exec: $!\n";

#    my( $fh, $filename ) = tempfile();
#    my_system( "$cmd 2> $filename" ); 
#
#    if ( $? >> 8 ) {     # non-zero exit status from socat/unixterm 
#        my @stderr = <$fh>;
#        Die "connect to $sock failed: command '$cmd' stderr: @stderr"; 
#    }
#
#    return( report_retval() );
}

1;
