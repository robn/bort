package Bort::Plugin::React;

use 5.014;
use warnings;
use strict;

Bort->add_context_method(react => sub {
  my ($ctx, $emoji, $message_id) = @_;
  Bort->slack_call("reactions.add",
    channel => $ctx->channel,
    timestamp => $message_id // $ctx->message_id,
    name => $emoji,
  );
});

Bort->add_context_method(react_remove => sub {
  my ($ctx, $emoji, $message_id) = @_;
  Bort->slack_call("reactions.remove",
    channel => $ctx->channel,
    timestamp => $message_id // $ctx->message_id,
    name => $emoji,
  );
});

1;
