package Bort::Plugin::React;

use 5.014;
use warnings;
use strict;

Bort->AddPluginMethod("React", sub {
  my (undef, $Emoji, $MessageId) = @_;
  Bort->SlackCall("reactions.add",
    channel => Bort->Channel,
    timestamp => $MessageId // Bort->MessageId,
    name => $Emoji,
  );
});

Bort->AddPluginMethod("ReactRemove", sub {
  my (undef, $Emoji, $MessageId) = @_;
  Bort->SlackCall("reactions.remove",
    channel => Bort->Channel,
    timestamp => $MessageId // Bort->MessageId,
    name => $Emoji,
  );
});

1;
