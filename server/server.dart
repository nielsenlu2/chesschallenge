import 'dart:io';
import 'dart:async';
import 'dart:convert' show JSON, LATIN1, LineSplitter, UTF8;
import 'dart:math';
import 'package:client/shared.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:path/path.dart' as path;

Map<WebSocket, User> users = {};

List<Challenge> challenges = [];

List<String> pgnGames = [];

const GAMES_PER_CHALLENGE = 5;

const PENDING_CHALLENGE_TIME = 10;

Challenge pendingChallenge = null;

Stopwatch pendingChallengeStopwatch = new Stopwatch();

class Challenge {
  List<WebSocket> webSockets = [];
  List<String> games = [];
  Stopwatch stopWatch = new Stopwatch();

  Challenge() {
    addRandomGames(GAMES_PER_CHALLENGE);
  }

  void addRandomGames(int count) {
    var rnd = new Random();
    int length = pgnGames.length;
    for (int i = 0; i < count; i++) {
      int index = rnd.nextInt(length);
      games.add(pgnGames[index]);
    }
  }

  List<User> getUsers() {
    return webSockets.map((ws) => users[ws]).toList();
  }
}

Challenge findChallenge(webSocket) {
  for (var challenge in challenges) {
    if (challenge.webSockets.contains(webSocket)) {
      return challenge;
    }
  }
  return null;
}

void main() {
  // Server port assignment
  var portEnv = Platform.environment['PORT'];
  var port = portEnv != null ? int.parse(portEnv) : 9090;

  readGames('IB1419.pgn');

  var handler = webSocketHandler(onConnection);

  shelf_io.serve(handler, InternetAddress.ANY_IP_V4, port).then((server) {
    print('Serving at ws://${server.address.host}:${server.port}');
  });
}

void readGames(String fileName) {
  String pgn = '';

  final serverDir = path.dirname(Platform.script.toFilePath());
  final file = new File(serverDir + '/' + fileName);

  Stream<List<int>> inputStream = file.openRead();

  inputStream.transform(
      LATIN1.decoder).transform(new LineSplitter()).listen((String line) {
    if (line.trim().isEmpty) {
      if (pgn.contains('1.')) {
        if (pgn.contains('#')) {
          pgnGames.add(pgn);
        }
        pgn = '';
      }
    } else {
      pgn += line + '\n';
    }
  }, onDone: () {
    print('Ready with ${pgnGames.length} challenges.');
  }, onError: (e) {
    print(e.toString());
  });
}

List<User> getLeaderBoard(Challenge challenge) {
  return challenge.getUsers()..sort((u1, u2) => u2.score.compareTo(u1.score));
}

void onConnection(webSocket) {
  webSocket.listen((String message) {
    if (message.startsWith(Messages.LOGIN)) {
      users.remove(webSocket);
      var user =
          new User.fromMap(JSON.decode(message.substring(Messages.LOGIN.length)));
      print('Login received from ${user.name}');
      users.putIfAbsent(webSocket, () => user);
      // Send an update status to all other users
      sendUpdateStatus(webSocket);
    } else if (message == Messages.CHALLENGE) {
      print('Start/join challenge received from ${users[webSocket].name}');
      joinChallenge(webSocket);
      // Send an update status to all other users
      sendUpdateStatus(webSocket);
    } else if (message == Messages.CHECKMATE) {
      print('Checkmate received from ${users[webSocket].name}');
      User user = users[webSocket];
      user.score += 1;
      var challenge = findChallenge(webSocket);
      updateLeaderBoard(challenge);
      if (user.score == challenge.games.length) {
        // We have a winner!
        challenge.stopWatch.stop();
        challenges.remove(challenge);
        print('Sending gameover message');
        sendGameOver(challenge);
      } else {
        print('Sending new chess problem');
        webSocket.add(Messages.PGN + challenge.games[user.score]);
      }
    } else if (message == Messages.STOPCHALLENGE) {
      print('Stop challenge received from ${users[webSocket].name}');
      var challenge = findChallenge(webSocket);
      if (challenge != null) {
        challenge.webSockets.remove(webSocket);
        if (challenge.webSockets.length == 0) {
          challenge.stopWatch.stop();
          challenges.remove(challenge);
        }
        updateLeaderBoard(challenge);
      }
      sendUpdateStatus(webSocket);
    }
  }, onDone: () => doneHandler(webSocket));
}

void sendUpdateStatus(webSocket) {
  List<User> availableUsers = getAvailableUsers();
  for (var ws in users.keys) {
    User user = users[ws];
    if (availableUsers.contains(user)){
      if (pendingChallenge != null) {
        List<User> leaderBoard = getLeaderBoard(pendingChallenge);
        int seconds =
            PENDING_CHALLENGE_TIME -
            pendingChallengeStopwatch.elapsed.inSeconds;
        print('Sending pending challenge to ${user.name} ${JSON.encode(leaderBoard)}');
        ws.add(
            Messages.PENDINGCHALLENGE +
                seconds.toString() +
                ":" +
                JSON.encode(leaderBoard));
      } else {
        List<User> otherUsers = getAvailableUsers()..remove(user);
        print('Sending available users to ${user.name} ${JSON.encode(otherUsers)}');
        ws.add(Messages.AVAILABLEUSERS + JSON.encode(otherUsers));
      }
    }
  }
}

/// Return the list of available users
List<User> getAvailableUsers() {
  List<User> availableUsers = [];
  for (var ws in users.keys) {
    if (findChallenge(ws) == null) {
      availableUsers.add(users[ws]);
    }
  }
  return availableUsers;
}

void sendGameOver(Challenge challenge) {
  var msg =
      Messages.GAMEOVER +
      challenge.stopWatch.elapsedMilliseconds.toString();
  for (var ws in challenge.webSockets) {
    ws.add(msg);
  }
}

void joinChallenge(dynamic webSocket) {
  leaveChallenge(webSocket);
  if (pendingChallenge == null) {
    pendingChallenge = new Challenge()..webSockets.add(webSocket);
    pendingChallengeStopwatch
        ..reset()
        ..start();
    var timer = new Timer.periodic(
        new Duration(seconds: PENDING_CHALLENGE_TIME),
        startChallenge);

  } else if (!pendingChallenge.webSockets.contains(webSocket)) {
    pendingChallenge.webSockets.add(webSocket);
  }
  updateLeaderBoard(pendingChallenge);
}

void updateLeaderBoard(Challenge challenge) {
  List<User> leaderBoard = getLeaderBoard(challenge);
  for (var ws in challenge.webSockets) {
    ws.add(Messages.LEADERBOARD + JSON.encode(leaderBoard));
  }
}

void startChallenge(Timer timer) {
  timer.cancel();
  pendingChallenge.stopWatch.start();
  challenges.add(pendingChallenge);
  updateLeaderBoard(pendingChallenge);
  sendStartChallenge(pendingChallenge);
  sendNewChessProblem(pendingChallenge);
  pendingChallenge = null;
}

void sendStartChallenge(Challenge pendingChallenge) {
  for (var ws in pendingChallenge.webSockets) {
    ws.add(Messages.STARTCHALLENGE);
  }
}

void sendNewChessProblem(Challenge pendingChallenge) {
  for (var ws in pendingChallenge.webSockets) {
    ws.add(Messages.PGN + pendingChallenge.games[0]);
  }
}

void doneHandler(webSocket) {
  leaveChallenge(webSocket);
  users.remove(webSocket);
}

void leaveChallenge(webSocket) {
  var user = users[webSocket];
  user.score = 0;
  var challenge = findChallenge(webSocket);
  if (challenge != null) {
    challenge.webSockets.remove(webSocket);
    if (challenge.webSockets.length == 0) {
      challenges.remove(challenge);
    }
  }
}
