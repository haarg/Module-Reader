use strict;
use ExtUtils::MakeMaker;
require 5.005_03;

WriteMakefile(
    NAME         => 'Module::Reader',
    VERSION_FROM => 'lib/Module/Reader.pm',

    PREREQ_PM => {
        ($] < 5.008 ? ('IO::String' => 0) : ()),
    },
);

