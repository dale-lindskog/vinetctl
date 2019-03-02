package Vinetctl::Debug;

use strict;
use warnings;
use Carp;
use Data::Dumper; 

use Vinetctl::Globals qw( %args );

use Exporter qw( import );
our @EXPORT_OK = qw( 
    Warn
    Die
    report_calling_stack
    report_retval
);

# Warn(): warn wrapper
#######################

sub Warn { 
    if ( $args{d} ) { carp "Warning: @_" }
    else            { warn "Warning: @_" }
}

# Die(): die wrapper
#####################

sub Die { 
    if ( $args{d} ) { croak "Fatal: @_" }
    else            { die   "Fatal: @_" }
}

# report_calling_stack(): debug stack (with -d)
################################################

sub report_calling_stack {
    my @params = @_;
    my( $current_file, $current_line, $current_sub ) = ( caller(1) )[1,2,3];
    my $calling_sub = ( caller(2) )[3];
    print STDERR "DEBUG: $current_file: ", 
               "entering  ${current_sub}() at line $current_line ",
                defined($calling_sub) ? "in ${calling_sub}() " : ' '; 

    if ( @params ) {
        print STDERR "with parameters: ";
        my $i = 1; 
        foreach my $param ( @params ) {
            my $type = ref( $param ); 
            if ( $args{v} and ($type eq 'ARRAY' or $type eq 'HASH') ) { 
                chomp( my $deref = Dumper($param) );
                print STDERR "($i) $deref "; 
            }
            else { print STDERR "($i) '$param' " }
            $i++; 
        }
    }
    print STDERR "\n"; 
}

# report_retval(): debug returns: reports and returns its parameter(s)
#######################################################################
# NOTE: we check for $args{d} inside this sub, so that we can just
# do 'return( report_retval(<retval>) ) and not worry about a decision
#######################################################################

sub report_retval { 

    if ( $args{d} ) {

        my $type = ref( $_[0] );
        my $calling_sub = ( caller(1) )[3];
        print STDERR "DEBUG: returning "; 

        if ( wantarray ) { print STDERR "'@_' " } 
        elsif (defined wantarray ) { 
            if ( $args{v} and ($type eq 'ARRAY' or $type eq 'HASH') )   { 
                chomp( my $deref = Dumper($_[0]) );
                print STDERR "'$deref' "; 
            }
            else { print STDERR "'$_[0]' " }
        }

        print STDERR "from $calling_sub\n"; 

    }

    if    ( wantarray )        { return @_  }     # array
    elsif ( defined wantarray) { return $_[0] }   # scalar
    else                       { return undef }   # void

    return( wantarray() == 0 ? undef :
            @_ == 1 ? $_[0] :
            @_                );

}

1;
