*ARCHIVED*. If you're looking for a Perl chat bot for Slack, Discord, IRC, etc, [Synergy](https://github.com/fastmail/synergy) is a much better choice!

# bort

![](https://frinkiac.com/img/S06E04/736201/medium.jpg)

bort is a [Slack](https://slack.com/) [bot](https://api.slack.com/bot-users).  Or maybe, a framework for a Slack bot. It's loosely inspired by pretty much every chat bot ever, from [Infobot](https://en.wikipedia.org/wiki/Infobot) to [Hubot](https://hubot.github.com/) and everything in between.

## warning

This is early. I'm in the middle of adding code and plugins from our internal repo. There's no docs yet. There's a lot of cleanup and other things to do. But, if you fancy getting your hands dirty with a fun project, the code should be fairly straightforward and easy to play with. This warning will go when I consider this ready for general consumption.

## getting started

It's still early days, so documentation pretty much doesn't exist. To get it running, you need to [create a bot](https://my.slack.com/services/new/bot) in Slack and get an API token. Then create a config file called `bort.ini`, replacing `xxx` with your API token.

```ini
slack_api_token = xxx
```

Run `bin/bort` to start the bot up. You'll see output like this:

```
2016-03-11 14:21:15.000000 +1100 info  Bort::App: Loading plugins
2016-03-11 14:21:15.565673 +1100 info  Bort::App: Connecting to Slack...
2016-03-11 14:21:22.280467 +1100 info  Bort::App: Slack says hello!
2016-03-11 14:21:22.281896 +1100 info  Bort::App: Starting name/channels update...
2016-03-11 14:21:23.319314 +1100 info  Bort::App: 13 channels loaded
2016-03-11 14:21:24.004807 +1100 info  Bort::App: 29 users loaded
2016-03-11 14:21:24.004894 +1100 info  Bort::App: My name is bort [U0J3W5327]
```

Now you can talk to it:

![](http://i.imgur.com/EtcV1rA.png)

Of course, not much can be done without plugins.

## where did this come from

It was built at [FastMail](https://www.fastmail.com/) as a [ChatOps](https://www.pagerduty.com/blog/what-is-chatops/) bot, and we talk to it all day long. These days it's doing deployments, showing graphs, sending pages, doing basic user admin jobs and helping us manage our task lists. All with a smile on it's face :)

## credits and license

Copyright (c) 2016 FastMail. Perl 5 license. See http://dev.perl.org/licenses/.

## contributing

Please hack on this and send pull requests :)

