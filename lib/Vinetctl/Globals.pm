package Vinetctl::Globals;

# This package exports all the global variables used by vinetctl
#################################################################

use strict; 
use warnings; 
use Hash::Util qw( lock_keys );

use Exporter qw( import ); 
our @EXPORT_OK = qw(
    %rc
    %args
    %globals
);

# global array ahd hash variables
##################################

our( %rc,                 # run control variables
     %args,               # getopts
);

our %globals = (          # %globals is mostly set in main()

    action_name    => undef, 
    top_owner      => undef, 
    ipaddr         => undef, 
    topology_name  => undef, 
    pid_file       => undef, 
    pid_file_value => undef,
    dialog_loop    => undef,
    rmcable_params => [],
    monitor_params => [],
    action_params  => [],
    dup_params     => [],
    topology       => [],
    vm_list        => [],
);

lock_keys( %globals );

1;
