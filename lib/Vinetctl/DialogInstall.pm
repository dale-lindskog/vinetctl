package Vinetctl::DialogInstall;

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
use UI::Dialog; 
use Hash::Util qw( hash_locked unlock_value lock_value );
use File::Path qw( make_path );
use constant { TRUE => 1, FALSE => 0 };
use File::Basename qw( basename ); 

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

use Vinetctl::AllAction qw( 
    get_all_images
);

use Vinetctl::Topology qw( 
    create_vm_hashref
);

use Vinetctl::StartRestoreAction qw( 
    vm_cmdline
    start_vm
);

use Vinetctl::Tmux qw(
    tmux_new_session
    tmux_cmd
    tmux_attach 
    tmux_has_session
);

use Vinetctl::Util qw(
    my_system
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    dialog_install_action
);

# TODO: moved this hash here, to be global, 
# because we access it in the dialog_connect()
# sub below; better way to do this?
my %info = ( 
    install_media => 'obsd63.iso', 
    disk => '1G', 
    memory => '256M', 
    network => 'NONE', 
    display => {},
    driver => 'virtio', 
);


# do_dialog_install(): UI to OS installation
#############################################

sub dialog_install_action {
    report_calling_stack(@_) if $args{d};

    $info{display}->{name} = 'curses';

    # change default image directory
    local $rc{vm_img_dir} = "$ENV{HOME}/$rc{user_dir}/install_images";

    DIALOG_INSTALL: for (;;) {

        select STDOUT;

        # for the various dirs (pids etc)
        unlock_value( %globals, 'topology_name' ) 
            if hash_locked( %globals );
        $globals{topology_name} = 'INSTALL'; 
        lock_value( %globals, 'topology_name' )
            if hash_locked( %globals );

        my $string = dialog_install_menu( \%info ); 

        my $retval; 
        if ( $string eq 'install media' ) { 
            $retval = dialog_choose_install();
            if ( defined $retval and $retval ne 'CANCEL' ) {
                $info{install_media} = $retval; 
            }
        }
        elsif ( $string eq 'disk' ) { 
            $retval = dialog_create_disk(); 
            $info{disk} = $retval
                unless $retval eq 'CANCEL'; 
        }
        elsif ( $string eq 'memory' ) { 
            $retval = dialog_choose_memory(); 
            $info{memory} = $retval 
                unless $retval eq 'CANCEL'; 
        }
        elsif ( $string eq 'network' ) {
            $retval = dialog_choose_network();
            $info{network} = $retval 
                unless $retval eq 'CANCEL'; 
        }
        elsif ( $string eq 'display' ) {
            my( $name, $port, $pword ) = 
                dialog_choose_display();
            if ( defined $name and $name ne 'CANCEL' ) { 
                $info{display}->{name} = $name; 
                if ( $name eq 'spice' ) {
                    ( $info{display}->{port}, $info{display}->{pword} ) 
                        = ( $port, $pword )
                }
            }
        }
        elsif ( $string eq 'virt driver' ) {
            $retval = dialog_toggle_virt_driver(); 
            if ( $retval eq '1' ) { $info{driver} = 'virtio' }
            elsif ( $retval eq '0' ) { $info{driver} = 'none' }
            elsif ( $retval eq 'CANCEL' ) { }
            else { 
                Die "BUG: dialog_toggle_virt_driver() returned something weird\n"; 
            }
        }
        # TODO: basify install images
        elsif ( $string eq 'connect' ) { 
            dialog_connect(); 
            # if we don't exit here, the connect failed, so: 
            my $d = new UI::Dialog ( 
                backtitle => 'Vinetctl', 
                title => "OS Installation", 
                height => 5, 
                width => 80, 
                listheight => 3, 
                order => [ 'CDialog', 'Whiptail'], 
            );

            $d->msgbox( title => 'Vinetctl', 
                        text => 'No installations in progress' 
            );
        }
        elsif ( $string eq 'done' ) { 
            if ( tmux_has_session( 
                     "$rc{tmux_sock_prefix}-$globals{topology_name}", 
                     'INSTALL',
                 )
            ) 
            {
                my $d = new UI::Dialog ( 
                    backtitle => 'Vinetctl', 
                    title => "OS Installation", 
                    height => 5, 
                    width => 80, 
                    listheight => 3, 
                    order => [ 'CDialog', 'Whiptail'], 
                );
        
                $d->msgbox( title => 'Vinetctl', 
                            text => "Installation in progress", 
                );
        
            }
            else {
                last DIALOG_INSTALL; 
            }
        }
        elsif ( $string eq 'CANCEL' ) { 
            return( report_retval($string) ) 
        } 
        # else something else when we're done

        # all values must be defined: 
        my @values = values %info;
        foreach (@values) { 
            redo DIALOG_INSTALL unless defined; 
        }
    }
    # if we're here, then we're ready to proc the install

#    $args{n} = 1;   # for testing

    my $vm = create_vm_hashref(); 
    $vm->{name}   = 'install_' . 
                    substr( $info{install_media}, 0, -4 );  # snip off '.iso'
    $vm->{images} = [ "$vm->{name}.qcow2" ]; 
    $vm->{memory} = $info{memory};
    $vm->{cdrom}  = "$info{install_media}"; 
    $vm->{display}->{name} = $info{display}->{name}; 
    $vm->{display}->{port} = $info{display}->{port}; 
    $vm->{display}->{pword} = $info{display}->{pword}; 
    $vm->{driver} = $info{driver}; 

    if ( -e "$rc{vm_img_dir}/$vm->{name}.qcow2" ) {
        my $d = new UI::Dialog ( 
                    backtitle => 'Vinetctl', 
                    title => "OS Installation", 
                    height => 5, 
                    width => 80, 
                    listheight => 3, 
                    order => [ 'CDialog', 'Whiptail'], 
                );
        my $image = "$rc{vm_img_dir}/$vm->{name}.qcow2"; 
        if( $d->yesno(text => "An image exists.  Delete it?") ) { 
            unlink $image; 
        }
        else { goto DIALOG_INSTALL }  # TODO: bad bad bad!!
    }

    unless ( $info{network} eq 'NONE' ) {
        my %nic; 
        $nic{mac} = '52:54:00:12:34:56';     # think this is qemu's default
        $nic{netdev} = 'tap'; 
        $nic{remote} = $info{network};
        push( @{ $vm->{nics} }, \%nic );
    }

    my $qemu_img_cmd = "$rc{qemu_img} " .
                      'create -f qcow2 ' .
                      "$rc{vm_img_dir}/$vm->{name}.qcow2 " .
                      "$info{disk}"; 

    # we make $rc{vm_img_dir} because we localized the var above,
    # and set to the 'install' directory
    make_path( "$rc{socket_dir}/$globals{topology_name}",
               "$rc{pid_dir}/$globals{topology_name}",
               "$rc{stderr_dir}/$globals{topology_name}", 
                $rc{vm_img_dir}, 
    );

    my_system( "$qemu_img_cmd >/dev/null 2>> $rc{log_file}" );
    tmux_new_session( "$rc{tmux_sock_prefix}-$globals{topology_name}", 
                        $globals{topology_name}, 
                        undef );

    start_vm( $vm, vm_cmdline(0, $vm, $globals{topology_name}) );

    # kill the 0th window
    tmux_cmd( "$rc{tmux_sock_prefix}-$globals{topology_name}",
              "$globals{topology_name}:0",
              'kill-window'                                     );

    my $sock = "$rc{tmux_sock_prefix}-$globals{topology_name}"; 
    if ( tmux_has_session($sock, 'INSTALL') ) {
        tmux_attach( 'rw', $sock, 'INSTALL', FALSE )
    }
#    return( report_retval(1) );
}

sub dialog_install_menu {
    report_calling_stack(@_) if $args{d};

    my $info = shift; 

    my $action_menu = [
        'Install Media'
            => "($info->{install_media})", 
        'Disk'
            => "($info->{disk})", 
        'Memory' 
            => "($info->{memory})", 
        'Network' 
            => "($info->{network})", 
        'Connect'
            => 'Connect to a running installation', 
        'Display'
            => "($info->{display}->{name})", 
        'Virt driver' 
            => "($info->{driver})", 
        'Done'
            => "",
    ]; 

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "OS Installation", 
        height => scalar( keys(%$info) ) + 8, 
        width => 80, 
        listheight => scalar( keys(%$info) ) + 5, 
        order => [ 'CDialog', 'Whiptail'], 
    );

    # TODO: string returns undefined when /tmp filesystem is full: very obscure!
    # make sure to check UI::Dialog's errors on this, probably get a 'no space'
    # type message
    my $string = 
        $d->menu( text => "Install an OS           Select an action:",
                  list => $action_menu   );

    if ( $d->state() eq 'OK' ) { return( report_retval(lc $string) ) }
    elsif ( $d->state() eq 'CANCEL' ) { return( report_retval('CANCEL') ) }
    else { Die "dialog menu returned nothing\n" }

}

sub dialog_choose_install {
    report_calling_stack(@_) if $args{d};

    my @list = grep { m/\.iso$/ } @{ get_all_images() };

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose install media", 
        height => scalar(@list)+8, 
        width => 80, 
        listheight => scalar(@list)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );
    my $retval = 
        dialog_install_set_from_list( 'Set install media from list', @list ); 

    if ( $retval eq 'CANCEL' ) { return( report_retval() ) } 
    return( report_retval($retval) );
}

sub dialog_choose_display {
    report_calling_stack(@_) if $args{d};

    my @types = ( 'curses', 'spice', 'nographic' );
 
    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose console", 
        height => scalar(@types)+8, 
        width => 80, 
        listheight => scalar(@types)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );

   my $display = 
        dialog_install_set_from_list( 'Set display from list', @types ); 

    if ( $display eq 'CANCEL' ) { return( report_retval() ) } 

#    my( $port, $pword ) = dialog_choose_spice_params()
#        if $display eq 'spice';

    my( $port, $pword ) = 
        $display eq 'spice' ? dialog_choose_spice_params() 
                            : ( 'NULL', 'NULL' );

    # TODO: don't return, loop back to previous menu
    if ( $port eq 'CANCEL' ) { return( report_retval() ) }

    return( report_retval($display, $port, $pword) );
}

sub dialog_toggle_virt_driver { 
    report_calling_stack(@_) if $args{d};

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Toggle virt drivers", 
#        height => scalar(@types)+8, 
        width => 80, 
#        listheight => scalar(@types)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );
    my $selection = $d->checklist( 
        text => 'Select to enable virtualization drivers: ', 
        list => [ 'enable', [ 'enable', 1 ] ]
    ); 
    return( report_retval($selection) );
}

sub dialog_choose_spice_params {
    report_calling_stack(@_) if $args{d};

    my $d = new UI::Dialog (
        backtitle => 'Vinetctl', 
        title => "Specify spice port and password", 
        width => 80, 
        order => [ 'CDialog', 'Whiptail'], 
    ); 

    # port: 
    my $port =
        $d->inputbox( text => 'Choose a TCP port for the spice console:',
                  entry => '5901', 
        );
    if    ( $d->state() eq 'CANCEL' ) {
        return( report_retval('CANCEL') );
    }
    elsif ( $d->state() eq 'ESC' ) {
        exit 0;
    }

    # password: 
    my $pword =
        $d->password( text => 'Choose a password for the spice console:',
                  entry => '' 
        );
    if    ( $d->state() eq 'CANCEL' ) {
        return( report_retval('CANCEL') );
    }
    elsif ( $d->state() eq 'ESC' ) {
        exit 0;
    }
    return( report_retval( $port, $pword ) );
}

sub dialog_connect { 
    report_calling_stack(@_) if $args{d};

    my $sock = "$rc{tmux_sock_prefix}-$globals{topology_name}"; 

    return( report_retval() )
        unless ( tmux_has_session($sock, 'INSTALL') ); 

    # if we're here, the tmux sessions exists

    my @list = ( 'console', 'monitor' );
    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose connection interface", 
        height => scalar(@list)+8, 
        width => 80, 
        listheight => scalar(@list)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );

    my $retval = dialog_install_set_from_list( 
        'Choose what interface to connect to', 
        @list
    ); 

    if ( $retval eq 'console' ) { 
        tmux_attach( 'rw', $sock, 'INSTALL', FALSE ); 
        exit(0); 
    }
    elsif ( $retval eq 'monitor' ) { 
        # TODO: this derivation of sockpath is cut-and-paste; should find 
        # some more general solution here
        my $sockname = 'install_' . 
                        substr( $info{install_media}, 0, -4 );  # snip off '.iso'
        my $sock     = join( '/',
                       $rc{socket_dir},
                       $globals{topology_name},
                       $sockname                );

        -e $sock
            or Die "monitor socket", basename($sock), "doesn't exist\n";
        -S _
            or Die "monitor socket", basename($sock), "not a socket!\n";

        my $cmd = ( -e $rc{socat} ? "$rc{socat} - UNIX-CONNECT:" :
                                    "$rc{unixterm} " )
                                  . $sock;
        # we unlink pid file since we won't run exit handler at END of vinetctl
        # TODO: this unlink is cut-and-paste; is it necessary here? 
        unlink $globals{pid_file}
            or Warn "cannot unlink $globals{pid_file}: $!\n";

        exec $cmd or Die "couldn't exec: $!\n"; 
    }

    # no return!
}

sub dialog_create_disk {
    report_calling_stack(@_) if $args{d};

    my @list = ( '1G', '2G', '5G', '10G', '20G' );

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose install media", 
        height => scalar(@list)+8, 
        width => 80, 
        listheight => scalar(@list)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );
    my $retval = dialog_install_set_from_list( 
        'Choose/Set disk image size', 
        @list 
    ); 
    return( report_retval($retval) );
}

sub dialog_choose_memory {
    report_calling_stack(@_) if $args{d};

    my @list = ( '128M',  '256M', '512M', '1G', '5G' );

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose memory amount", 
        height => scalar(@list)+8, 
        width => 80, 
        listheight => scalar(@list)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );
    my $retval = dialog_install_set_from_list( 'Choose/Set memory size', @list );
    return( report_retval($retval) );
}

sub dialog_choose_network {
    report_calling_stack(@_) if $args{d};

    my @list = qw( NONE tap0 tap1 tap2 );    # TODO: tap from UID, put it first

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Choose network", 
        height => scalar(@list)+8, 
        width => 80, 
        listheight => scalar(@list)+5, 
        order => [ 'CDialog', 'Whiptail'], 
    );

    my $retval = 
        dialog_install_set_from_list( 'Set network from list', @list ); 
    return( report_retval($retval) );
    if ( $retval eq 'CANCEL' ) { return( report_retval() ) } 
}

# dialog_install_set_from_list(): This just like sub dialog_set_from_list(), 
# except not assuming we're choosing a topology
#############################################################################

sub dialog_install_set_from_list {
    report_calling_stack(@_) if $args{d};

    my $title = shift;
    Die( "BUG: no list passed as parameter!\n" )
        unless @_; 

    my @list = @_; 

    # TODO: figure why we gotta loop and push here
    my @menulist; 
    for( my $i = 0; $i < @list; $i++ ) {
        push @menulist, $list[$i], '';
    }

    my $d = new UI::Dialog (
        backtitle => 'Vinetctl',
        title => "$title",
        height => scalar(@list)+8,
        width => 40,
        listheight => scalar(@list)+5,
        order => [ 'CDialog', 'Whiptail'],
    );
    my $choice =
        $d->menu( text => 'Select:',
                  list => \@menulist     );

    if    ( $d->state() eq 'CANCEL' ) {
        return( report_retval('CANCEL') );
    }
    elsif ( $d->state() eq 'ESC' ) {
        exit 0;
    }
    return( report_retval($choice) );
}

1;
