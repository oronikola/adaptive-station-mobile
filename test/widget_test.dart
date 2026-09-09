import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:adaptivemobile_station/data/gateway_sender_repository.dart';
import 'package:adaptivemobile_station/main.dart';
import 'package:adaptivemobile_station/services/theme_controller.dart';
import 'support/fake_parent_repository.dart';

void main() {
  setUpAll(() async {
    final loader = FontLoader('Plus Jakarta Sans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(
        rootBundle.load('assets/fonts/PlusJakartaSans-$weight.ttf'),
      );
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('Phone dashboard and child attendance navigation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      StationParentApp(
        parentRepository: FakeParentRepository(),
        gatewayRepository: GatewaySenderRepository(),
        themeController: ThemeController(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Both children tapped in'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(StationParentApp),
      matchesGoldenFile('previews/dashboard-phone.png'),
    );
    await tester.ensureVisible(find.text('View attendance').first);
    await tester.tap(find.text('View attendance').first);
    await tester.pumpAndSettle();
    expect(find.text('Alex Santos tapped OUT'), findsOneWidget);
    expect(find.text('Mia Santos tapped IN'), findsNothing);
    await tester.tap(find.text('All children'));
    await tester.pumpAndSettle();
    expect(find.text('Mia Santos tapped IN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tablet uses sidebar and displays dashboard without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(1280, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      StationParentApp(
        parentRepository: FakeParentRepository(),
        gatewayRepository: GatewaySenderRepository(),
        themeController: ThemeController(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Alex Santos'), findsOneWidget);
    expect(find.text('Mia Santos'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(StationParentApp),
      matchesGoldenFile('previews/dashboard-tablet.png'),
    );
  });

  testWidgets('Small phone supports large text and preference controls', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      StationParentApp(
        parentRepository: FakeParentRepository(),
        gatewayRepository: GatewaySenderRepository(),
        themeController: ThemeController(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Account').last);
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
