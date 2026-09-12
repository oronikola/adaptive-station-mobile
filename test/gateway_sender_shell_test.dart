import 'package:adaptivemobile_station/data/api_client.dart';
import 'package:adaptivemobile_station/data/gateway_sender_repository.dart';
import 'package:adaptivemobile_station/features/gateway/gateway_sender_shell.dart';
import 'package:adaptivemobile_station/services/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_data_new/sim_data.dart';

import 'support/fake_gateway_realtime_service.dart';
import 'support/fake_gateway_sender_repository.dart';
import 'support/fake_sim_sms_sender.dart';

const _testSim = SimCard(
  carrierName: 'Test Telecom',
  countryCode: 'PH',
  displayName: 'Test SIM',
  isNetworkRoaming: false,
  isDataRoaming: false,
  mcc: 515,
  mnc: 3,
  slotIndex: 0,
  serialNumber: '0000',
  subscriptionId: 1,
  phoneNumber: '+639170000000',
);

Future<void> _pumpShell(
  WidgetTester tester, {
  required GatewaySenderRepository repository,
  required FakeSimSmsSender smsSender,
  required FakeGatewayRealtimeService realtime,
  List<SimCard> simCards = const [_testSim],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GatewaySenderShell(
        repository: repository,
        onLoggedOut: () {},
        themeController: ThemeController(),
        smsSender: smsSender,
        debugRealtimeService: realtime,
        debugInitialSimCards: simCards,
      ),
    ),
  );
  await _settle(tester);
}

/// The claim -> send -> report chain is several sequential `await`s deep —
/// including _start()'s 3-second-timeout-guarded WakelockPlus/foreground-
/// service calls, neither of which a widget test's platform can actually
/// answer — so a single pump() (which only flushes what's already queued)
/// isn't enough. pumpAndSettle() can't be used either, since the "LIVE"
/// badge's radar-pulse animation loops forever and never lets it settle. A
/// fixed, generous number of 1-second pumps sidesteps both problems.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Once a test's message queue drains, _loopForSim is left idling on
/// Future.any([Future.delayed(_pollInterval), _wakeEvents.stream.first]) —
/// a genuinely pending Dart Timer that the test framework will flag as a
/// leak if the test ends without it resolving. Disposing the widget first
/// (so _running flips false) and then advancing the fake clock past both
/// possible wait durations lets that pending wait resolve and the loop exit
/// cleanly, instead of the test finishing with an unresolved Timer.
Future<void> _disposeAndSettle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 16));
}

void main() {
  testWidgets('a claimed message is sent and shows as Sent', (tester) async {
    final repository = FakeGatewaySenderRepository(
      queue: [
        const GatewayMessage(id: 'm1', phoneNumber: '+639171111111', message: 'Alex tapped IN'),
      ],
    );
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(tester, repository: repository, smsSender: smsSender, realtime: realtime);

    // 2, not 1: the "Sent" stat-card label is always on screen (even at
    // count 0) in addition to this record's own status pill.
    expect(find.text('Sent'), findsNWidgets(2));
    expect(find.textContaining('+639171111111'), findsOneWidget);
    expect(repository.reportedSent, ['m1']);
    expect(smsSender.sentMessages, hasLength(1));
    expect(smsSender.sentMessages.first['phoneNumber'], '+639171111111');

    await _disposeAndSettle(tester);
  });

  testWidgets('a failed send is reported and shows as Failed', (tester) async {
    final repository = FakeGatewaySenderRepository(
      queue: [
        const GatewayMessage(id: 'm2', phoneNumber: '+639172222222', message: 'Mia tapped OUT'),
      ],
    );
    final smsSender = FakeSimSmsSender()..nextSendResult = 'error: no service';
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(tester, repository: repository, smsSender: smsSender, realtime: realtime);

    expect(find.text('Failed'), findsNWidgets(2)); // stat-card label + status pill
    expect(find.text('no service'), findsOneWidget);
    expect(repository.reportedFailed, [('m2', 'no service')]);

    await _disposeAndSettle(tester);
  });

  testWidgets('a delivery report updates a sent message to Delivered', (tester) async {
    final repository = FakeGatewaySenderRepository(
      queue: [
        const GatewayMessage(id: 'm3', phoneNumber: '+639173333333', message: 'Jamie tapped IN'),
      ],
    );
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(tester, repository: repository, smsSender: smsSender, realtime: realtime);
    expect(find.text('Sent'), findsNWidgets(2)); // stat-card label + this record's pill

    smsSender.emitDeliveryReport('m3', delivered: true);
    await _settle(tester);

    // The pill switched from "Sent" to "Delivered" — only the stat-card
    // label still says "Sent" now, while "Delivered" shows up twice (its
    // own stat-card label + this record's pill).
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Delivered'), findsNWidgets(2));
    expect(repository.reportedDelivered, ['m3']);

    await _disposeAndSettle(tester);
  });

  testWidgets('a delivery report for an unknown message id is ignored, not a crash', (tester) async {
    final repository = FakeGatewaySenderRepository();
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(tester, repository: repository, smsSender: smsSender, realtime: realtime);

    smsSender.emitDeliveryReport('never-sent', delivered: true);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(repository.reportedDelivered, isEmpty);

    await _disposeAndSettle(tester);
  });

  testWidgets('a wake-up event triggers an immediate claim instead of waiting the poll interval', (tester) async {
    final repository = FakeGatewaySenderRepository();
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(tester, repository: repository, smsSender: smsSender, realtime: realtime);
    final claimsBeforeWakeUp = repository.claimCalls;

    realtime.triggerWakeUp();
    await _settle(tester);

    expect(repository.claimCalls, greaterThan(claimsBeforeWakeUp));

    await _disposeAndSettle(tester);
  });

  testWidgets('two SIMs claim and send independently', (tester) async {
    const secondSim = SimCard(
      carrierName: 'Test Telecom 2',
      countryCode: 'PH',
      displayName: 'Test SIM 2',
      isNetworkRoaming: false,
      isDataRoaming: false,
      mcc: 515,
      mnc: 3,
      slotIndex: 1,
      serialNumber: '0001',
      subscriptionId: 2,
      phoneNumber: '+639170000001',
    );
    final repository = FakeGatewaySenderRepository(
      queue: [
        const GatewayMessage(id: 'm4', phoneNumber: '+639174444444', message: 'a'),
        const GatewayMessage(id: 'm5', phoneNumber: '+639175555555', message: 'b'),
      ],
    );
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();

    await _pumpShell(
      tester,
      repository: repository,
      smsSender: smsSender,
      realtime: realtime,
      simCards: const [_testSim, secondSim],
    );

    // 3: the "Sent" stat-card label plus one status pill per message.
    expect(find.text('Sent'), findsNWidgets(3));
    expect(repository.reportedSent, containsAll(['m4', 'm5']));
    final usedSubscriptions = smsSender.sentMessages.map((m) => m['subscriptionId']).toSet();
    expect(usedSubscriptions, {'1', '2'});

    await _disposeAndSettle(tester);
  });

  testWidgets('a 401 from claim() stops the loop and logs the device out', (tester) async {
    final repository = FakeGatewaySenderRepository()
      ..nextClaimError = ApiException('Session revoked.', statusCode: 401);
    final smsSender = FakeSimSmsSender();
    final realtime = FakeGatewayRealtimeService();
    var loggedOut = false;

    await tester.pumpWidget(
      MaterialApp(
        home: GatewaySenderShell(
          repository: repository,
          onLoggedOut: () => loggedOut = true,
          themeController: ThemeController(),
          smsSender: smsSender,
          debugRealtimeService: realtime,
          debugInitialSimCards: const [_testSim],
        ),
      ),
    );
    await _settle(tester);
    await _settle(tester);

    expect(loggedOut, isTrue);
    expect(find.text('Session expired. Please log in again.'), findsOneWidget);

    await _disposeAndSettle(tester);
  });
}
