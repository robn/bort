package Bort::Plugin::Help;

use 5.014;
use warnings;
use strict;

my %HelpText;

Bort->AddPluginMethod("AddHelp", sub {
  my (undef, $Topic, @Lines) = @_;
  $HelpText{lc $Topic} = [ map { s/[\r\n]$//mr } @Lines ];
  Bort->Log("Added help topic: $Topic");
});

sub Init {
  Bort->AddCommandWatch(help => sub {
    my ($Topic) = @_;

    unless (defined $Topic) {
      state $TopHelp = [ map {
        chomp;
        s/%topics%/join ", ", sort(keys %HelpText)/er;
      } <DATA> ];

      Bort->Reply([{ text => join("\n", @$TopHelp), fallback => $TopHelp->[0] }]);
      return;
    }

    $Topic = lc $Topic;
    if (exists $HelpText{$Topic}) {
      Bort->Reply([{ text => join("\n", @{$HelpText{$Topic}}), fallback => $HelpText{$Topic}->[0] }]);
    }
    else {
      Bort->Reply("no help for '$Topic'");
    }
  });

}

1;

__DATA__
Available help topics: %topics%
Usage: help <topic>
