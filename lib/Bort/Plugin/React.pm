package Bort::Plugin::React;

use 5.014;
use warnings;
use strict;

Bort->add_plugin_method(react => sub {
  my (undef, $emoji, $message_id) = @_;
  Bort->slack_call("reactions.add",
    channel => Bort->channel,
    timestamp => $message_id // Bort->message_id,
    name => $emoji,
  );
});

Bort->add_plugin_method(react_remove => sub {
  my (undef, $emoji, $message_id) = @_;
  Bort->slack_call("reactions.remove",
    channel => Bort->channel,
    timestamp => $message_id // Bort->message_id,
    name => $emoji,
  );
});

1;
