import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf_router/shelf_router.dart' as shelf;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

class IRCMessage {
  String raw;
  Map<String, String> tags;
  String? prefix;
  String command;
  List<String> parameters;

  IRCMessage({
    required this.raw,
    required this.tags,
    required this.prefix,
    required this.command,
    required this.parameters,
  });

  factory IRCMessage.fromEvent(String event) {
    final parts = event.split(' ');
    // if (parts.length < 2) {
    //   throw 'invalid irc message: $event';
    // }

    var tags = <String, String>{};
    if (parts.isNotEmpty && parts.first.startsWith('@')) {
      tags = <String, String>{
        for (final tag in parts.first.substring(1).split(';'))
          if (tag.contains('=')) tag.split('=').first: tag.split('=').skip(1).join('='),
      };

      parts.removeAt(0);
    }

    String? prefix;
    if (parts.isNotEmpty && parts.first.startsWith(':')) {
      prefix = parts.first.substring(1);
      parts.removeAt(0);
    }

    if (parts.isEmpty) {
      throw 'invalid irc message: $event';
    }

    final command = parts.first;
    parts.removeAt(0);

    final parameters = <String>[];
    for (int i = 0; i < parts.length; ++i) {
      final part = parts[i];
      if (part.startsWith(':')) {
        parameters.add(parts.skip(i).join(' ').substring(1));
        break;
      } else {
        parameters.add(part);
      }
    }

    return IRCMessage(
      raw: event,
      tags: tags,
      prefix: prefix,
      command: command,
      parameters: parameters,
    );
  }
}

class TMIClient {
  WebSocket? socket;
  Function(TMIClient self)? onConnect;
  Function(TMIClient self)? onDisconnect;
  Function(TMIClient self, IRCMessage message)? onEvent;

  Future<void> connect() async {
    socket = await WebSocket.connect('wss://irc-ws.chat.twitch.tv:443');

    socket?.listen(
      (event) {
        for (final singleEvent in event.trim().split('\r\n').where((String singleEvent) => singleEvent.isNotEmpty).map((String singleEvent) => singleEvent.trim())) {
          final message = IRCMessage.fromEvent(singleEvent);
          receive(message);
        }
      },
      cancelOnError: true,
      onDone: () async {
        onDisconnect?.call(this);
        await Future.delayed(Duration(seconds: 4));
        connect();
      },
      onError: (error) async {
        onDisconnect?.call(this);
        await Future.delayed(Duration(seconds: 4));
        connect();
      },
    );

    send('CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership');
    send('NICK justinfan6969');
  }

  Future<void> join(String login) async {
    send('JOIN #$login');

    final ingestServerUrl = Platform.environment['DEKKAI'];
    if (ingestServerUrl != null) {
      final channel = IOWebSocketChannel.connect(ingestServerUrl);
      channel.sink.add('join:${login.toLowerCase()}');
      await channel.sink.done;
      await channel.sink.close();
    }
  }

  Future<void> part(String login) async {
    send('PART #$login');
  }

  TMIClient({
    this.onConnect,
    this.onDisconnect,
    this.onEvent,
  }) {
    connect();
  }

  Future<void> receive(IRCMessage message) async {
    switch (message.command) {
      case '001':
        onConnect?.call(this);
        break;
      case 'PING':
        send('PONG :tmi.twitch.tv');
        break;
    }
    onEvent?.call(this, message);
  }

  Future<void> send(String message) async {
    socket?.add(message);
  }
}

enum ChannelState { disconnected, connecting, connected }

class Channel {
  String login;
  ChannelState state = ChannelState.connected;
  Map<String, DateTime> users = {};
  DateTime lastRequested = DateTime.now();
  Map<IRCMessage, DateTime> messages = {};

  Channel({
    required this.login,
  });
}

// TODO: Ratelimit onConnect's join logic
// TODO: Cache responses
// TODO: Ratelimit requests per IP
// TODO: Leave channels if not requested within 24 hours
// TODO: Sanitize user input
// TODO: Log roles (based on badges)

Future<void> main(List<String> arguments) async {
  final channels = <String, Channel>{};

  final client = TMIClient(
    onConnect: (self) {
      print('Client connected.');
      for (final channel in channels.entries.where((x) => x.value.state == ChannelState.disconnected)) {
        self.join(channel.key);
      }
    },
    onDisconnect: (self) {
      print('Client disconnected.');
      for (final channel in channels.entries) {
        channel.value.state = ChannelState.disconnected;
      }
    },
    onEvent: (self, message) {
      switch (message.command) {
        case 'JOIN':
          final channelName = message.parameters.first.substring(1);
          if (message.prefix?.split('!').first != 'justinfan6969') break;

          if (channels.containsKey(channelName)) {
            channels[channelName]!.state = ChannelState.connected;
          } else {
            channels[channelName] = Channel(
              login: channelName,
            );
          }
          break;
        case 'PRIVMSG':
          final channelName = message.parameters.first.substring(1);
          if (!channels.containsKey(channelName)) break;

          final login = message.prefix?.split('!').first;
          final channel = channels[channelName]!;
          channel.users[login!] = DateTime.now();
          channel.users.removeWhere((key, value) => DateTime.now().isAfter(value.add(Duration(minutes: 60))));
          // channel.messages[message] = DateTime.now();
          // channel.messages.removeWhere((key, value) => DateTime.now().isAfter(value.add(Duration(minutes: 60))));
          break;
      }
    },
  );

  final router = shelf.Router();

  router.get('/channel/history/<login>', (shelf.Request request, String login) {
    if (!channels.containsKey(login)) {
      client.join(login);
      return shelf.Response.ok(
        json.encode({}),
        headers: {
          'Content-Type': 'application/json',
        },
      );
    }
    final channel = channels[login]!;
    channel.lastRequested = DateTime.now();
    channel.messages.removeWhere((key, value) => DateTime.now().isAfter(value.add(Duration(minutes: 60))));
    return shelf.Response.ok(
      json.encode(channels[login]!.messages.keys.map((key) => key.raw).toList()),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  });

  router.get('/channel/users/<login>', (shelf.Request request, String login) {
    if (!channels.containsKey(login)) {
      client.join(login);
      return shelf.Response.ok(
        json.encode({}),
        headers: {
          'Content-Type': 'application/json',
        },
      );
    }
    final channel = channels[login]!;
    channel.lastRequested = DateTime.now();
    channel.users.removeWhere((key, value) => DateTime.now().isAfter(value.add(Duration(minutes: 60))));
    return shelf.Response.ok(
      json.encode(channels[login]!.users.map((key, value) => MapEntry(key, value.toIso8601String()))),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  });

  router.get('/user/<login>', (shelf.Request request, String login) {
    for (final channel in channels.entries) {
      if (channel.value.users.containsKey(login)) {
        return shelf.Response.ok(channel.key);
      }
    }
    return shelf.Response.notFound('');
  });

  router.get('/channels', (shelf.Request request) {
    return shelf.Response.ok(
      json.encode({
        for (final channel in channels.entries) channel.key: '${channel.value.state}',
      }),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  });

  final server = await shelf.serve(router, '0.0.0.0', int.tryParse(Platform.environment['PORT'] ?? '7777') ?? 7777);
  print('Server started on port ${server.port}');
}
