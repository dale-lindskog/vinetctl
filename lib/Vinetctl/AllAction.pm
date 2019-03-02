package Vinetctl::AllAction;

use strict;
use warnings;
use feature qw( say );

use File::Compare;  # for compare()

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
    get_uniq
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    all_action
    get_all_topologies
    get_all_images
);

# all_action(): show all topologies or images, as requested
############################################################

sub all_action {
    report_calling_stack(@_) if $args{d};

    my @params = @{ $globals{action_params} };
    my $msg = "usage: $rc{progname} $globals{action_name} [images]\n";

    @params == 0 or @params == 1 or Die $msg;

    if ( @params == 0 )              { show_all_topologies() }
    elsif ( $params[0] ne 'images' ) { Die $msg }
    else                             { show_all_images( $params[0] ) }

    return( report_retval() );
}

# get_all_images: return an aref of all images
###############################################

sub get_all_images {
    report_calling_stack(@_) if $args{d};

    my @all_images; 

    # open and read user's base image directory, populate lists
    ############################################################

    if ( -e $rc{priv_base_img_dir} ) {
        opendir( my $dh, $rc{priv_base_img_dir} )
            or Warn "cannot opendir $rc{priv_base_img_dir}: $!\n";
        foreach my $entry ( File::Spec->no_upwards(readdir($dh)) ) {
            next unless -f "$rc{priv_base_img_dir}/$entry" and -r _;
            push @all_images, $entry;
        }
        closedir $dh or Die "cannot closedir: $!\n";
    }

    # open and read global image directory, if it exists; populate list
    ####################################################################

    if ( -e $rc{base_img_dir} ) {
        opendir( my $dh, $rc{base_img_dir} )
            or Die "cannot opendir $rc{base_img_dir}: $!\n";
        foreach my $entry ( File::Spec->no_upwards(readdir($dh)) ) {
            next unless -f "$rc{base_img_dir}/$entry" and -r _;
            push @all_images, $entry;
        }
        closedir $dh or Die "cannot closedir: $!\n";
    } 
    elsif ( $args{v} ) { Warn "$rc{topology_base_dir} doesn't exist\n" }

    # return a unique list of all topologies
    #########################################

    @all_images = @{ get_uniq( \@all_images ) };

    return( report_retval( \@all_images ) );
}

# show_all_images: show all images
#####################################

sub show_all_images { 
    report_calling_stack(@_) if $args{d};

    my @all_images = @{ get_all_images() }; 

    # categorize into those in base dir, home dir, and *only* home dir
    my( @base_images,                    # those in base dir
        @home_images,                    # those only in user's home dir
    );

    # populate categorized arrays
    ##############################

    foreach my $image ( @all_images ) {

        if    ( -e "$rc{priv_base_img_dir}/$image" ) { 
            push @home_images, $image
        }
        elsif ( -e "$rc{base_img_dir}/$image" ) { 
            push @base_images, $image;
        }

    }

    # construct the output to print
    ################################

    # -p is set: show only thoses in user's topology directory
    if ( $args{p} ) { 
        @all_images = @home_images; 
        # tag with 'private' if -v:
        if ( $args{v} ) { $_ .= " [private]" foreach @all_images }
    }
    elsif ( $args{v} ) {
        # -v is set: tag each image name as private or base
        TOP: foreach my $image ( @all_images ) {
            # is the topology private to the user? 
            if ( grep { $image eq $_ } @home_images ) { 
                $image .= " [private]"; 
            }
            else { 
                $image .= " [base]"; 
            }
        }
    }

    # print the list
    say foreach @all_images;

    return( report_retval() );
}

# show_all_topologies(): show all topologies
###############################################

sub show_all_topologies {
    report_calling_stack(@_) if $args{d};

    # no parameters allowed for 'all' action
    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # get a list of all the topology files in both base and user dir
    my @all_topologies = @{ get_all_topologies() };

    # categorize into those in base dir, home dir, and *only* home dir
    my( @base_topologies,                    # those in base dir
        @home_topologies,                    # those in user's home dir
        @private_topologies,                 # those only in user's home dir
    );

    # topologies: populate categorized arrays
    ##############################################################

    foreach my $top ( @all_topologies ) {

        # doing this chk in Main.pm now, along with sanity chks on images
#        # no funny characters, except ~ at the end, for emacs users 
#        Die "$top: topology files may use A-Z, a-z, 0-9, - and _ only\n"
#            unless $top =~ /^[a-zA-Z0-9_-]+~?$/; 

        # categorize topologies:
        if ( -e "$rc{topology_dir}/$top" ) { 
            push @home_topologies, $top
        }
        if ( -e "$rc{topology_base_dir}/$top" ) { 
            push @base_topologies, $top;
        }
        else { push @private_topologies, $top }

    }

    # construct the output to print
    ################################

    # -p is set: show only thoses in user's topology directory
    if ( $args{p} ) { 
        @all_topologies = @private_topologies; 
        # tag with 'private' if -v:
        if ( $args{v} ) { $_ .= " [private]" foreach @all_topologies }
    }
    elsif ( $args{v} ) {
        # -v is set: tag each topology name as private, base, or modified
        TOP: foreach my $top ( @all_topologies ) {

            # is the topology private to the user? 
            if ( grep { $top eq $_ } @private_topologies ) { 
                $top .= " [private]" 
            } 

            # is the topology only in base (not yet copied)?
            elsif (         grep { $top eq $_ } @base_topologies
                    and not grep { $top eq $_ } @home_topologies )
            { $top .= " [base]" }

            # has the user modified a global topology?
            elsif (     grep { $top eq $_ } @base_topologies
                    and grep { $top eq $_ } @home_topologies
                    and compare("$rc{topology_base_dir}/$top", 
                                "$rc{topology_dir}/$top")      ) 
            { $top .= " [modified]" }

        }
    }

    # print the list
    say foreach @all_topologies;

    return( report_retval() );
}

# get_all_topologies(): return an aref of all topologies available
###################################################################

sub get_all_topologies {
    report_calling_stack(@_) if $args{d};

    my @topologies;

    # open and read user's topology directory, populate lists
    ##########################################################

    opendir( my $dh, $rc{topology_dir} )
        or Die "cannot opendir $rc{topology_dir}: $!\n";
    foreach my $entry ( File::Spec->no_upwards(readdir($dh)) ) {
        next unless -f "$rc{topology_dir}/$entry" and -r _;
        push @topologies, $entry;
    }
    closedir $dh or Die "cannot closedir: $!\n";

    # open and read global topology directory, if it exists; populate list
    #######################################################################

    if ( -e $rc{topology_base_dir} ) {
        opendir( my $dh, $rc{topology_base_dir} )
            or Die "cannot opendir $rc{topology_base_dir}: $!\n";
        foreach my $entry ( File::Spec->no_upwards(readdir($dh)) ) {
            next unless -f "$rc{topology_base_dir}/$entry" and -r _;
            push @topologies, $entry;
        }
        closedir $dh or Die "cannot closedir: $!\n";
    } 
    elsif ( $args{v} ) { Warn "$rc{topology_base_dir} doesn't exist\n" }

    # return a unique list of all topologies
    #########################################

    @topologies = @{ get_uniq( \@topologies ) };

    # strip out emacs savefiles 
    @topologies = grep { $_ !~ /~$/ } @topologies; 

    return( report_retval(\@topologies) );
}

1;
