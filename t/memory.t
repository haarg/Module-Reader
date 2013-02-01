use strict;
use warnings;

use Test::More 0.88;
use Module::Reader qw(:all);

my $mod_content = do {
    open my $fh, '<', 't/lib/TestLib.pm';
    local $/;
    <$fh>;
};

{
    local @INC = @INC;
    unshift @INC, sub {
        return unless $_[1] eq 'TestLib.pm';
        open my $fh, '<', \$mod_content;
        return $fh;
    };
    is module_content('TestLib'), $mod_content, 'correctly load module from sub @INC hook';
}

done_testing;
