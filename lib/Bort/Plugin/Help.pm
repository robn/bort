package Bort::Plugin::Help;

use 5.014;
use warnings;
use strict;

my %help_text;

Bort->add_plugin_method(add_help => sub {
  my (undef, $topic, @lines) = @_;
  $help_text{lc $topic} = [ map { s/[\r\n]$//mr } @lines ];
  Bort->log("Added help topic: $topic");
});

sub init {
  Bort->add_command_watch(help => sub {
    my ($topic) = @_;

    unless (defined $topic) {
      state $top_help = [ map {
        chomp;
        s/%topics%/join ", ", sort(keys %help_text)/er;
      } <DATA> ];

      Bort->reply([{ text => join("\n", @$top_help), fallback => $top_help->[0] }]);
      return;
    }

    $topic = lc $topic;
    if (exists $help_text{$topic}) {
      Bort->reply([{ text => join("\n", @{$help_text{$topic}}), fallback => $help_text{$topic}->[0] }]);
    }
    else {
      Bort->reply("no help for '$topic'");
    }
  });

}

1;

__DATA__
Available help topics: %topics%
Usage: help <topic>
