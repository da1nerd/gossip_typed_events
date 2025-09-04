import 'dart:async';

import 'package:gossip/gossip.dart';
import 'package:gossip_typed_events/gossip_typed_events.dart';
import 'package:test/test.dart';

/// Mock transport for testing
class MockTransport implements GossipTransport {
  final String nodeId;
  final Map<String, MockTransport> _network;

  final StreamController<IncomingDigest> _digestController =
      StreamController<IncomingDigest>.broadcast();
  final StreamController<IncomingEvents> _eventsController =
      StreamController<IncomingEvents>.broadcast();

  MockTransport(this.nodeId, this._network);

  @override
  Future<void> initialize() async {
    _network[nodeId] = this;
  }

  @override
  Future<void> shutdown() async {
    _network.remove(nodeId);
    await _digestController.close();
    await _eventsController.close();
  }

  @override
  Future<GossipDigestResponse> sendDigest(
    GossipPeer peer,
    GossipDigest digest, {
    Duration? timeout,
  }) async {
    final targetTransport = _network[peer.id];
    if (targetTransport == null) {
      throw TransportException('Peer ${peer.id} not reachable');
    }

    final completer = Completer<GossipDigestResponse>();
    final incomingDigest = IncomingDigest(
      fromPeer: GossipPeer(id: nodeId, address: 'mock://$nodeId'),
      digest: digest,
      respond: (response) async {
        completer.complete(response);
      },
    );

    targetTransport._digestController.add(incomingDigest);
    return completer.future;
  }

  @override
  Future<void> sendEvents(
    GossipPeer peer,
    GossipEventMessage message, {
    Duration? timeout,
  }) async {
    final targetTransport = _network[peer.id];
    if (targetTransport == null) {
      throw TransportException('Peer ${peer.id} not reachable');
    }

    final incomingEvents = IncomingEvents(
      fromPeer: GossipPeer(id: nodeId, address: 'mock://$nodeId'),
      message: message,
    );

    targetTransport._eventsController.add(incomingEvents);
  }

  @override
  Stream<IncomingDigest> get incomingDigests => _digestController.stream;

  @override
  Stream<IncomingEvents> get incomingEvents => _eventsController.stream;

  @override
  Future<List<GossipPeer>> discoverPeers() async {
    return _network.keys
        .where((id) => id != nodeId)
        .map((id) => GossipPeer(id: id, address: 'mock://$id'))
        .toList();
  }

  @override
  Future<bool> isPeerReachable(GossipPeer peer) async {
    return _network.containsKey(peer.id);
  }
}

/// Test event implementations
class TestUserEvent extends TypedEvent {
  final String userId;
  final String action;

  TestUserEvent({required this.userId, required this.action});

  @override
  String get type => 'test_user_event';

  @override
  Map<String, dynamic> toJson() => {'userId': userId, 'action': action};

  factory TestUserEvent.fromJson(Map<String, dynamic> json) {
    return TestUserEvent(
      userId: json['userId'] as String,
      action: json['action'] as String,
    );
  }
}

class TestOrderEvent extends TypedEvent with TypedEventMixin {
  final String orderId;
  final double amount;

  TestOrderEvent({required this.orderId, required this.amount});

  @override
  String get type => 'test_order_event';

  @override
  void validate() {
    super.validate();
    if (orderId.isEmpty) throw ArgumentError('orderId cannot be empty');
    if (amount <= 0) throw ArgumentError('amount must be positive');
  }

  @override
  Map<String, dynamic> toJson() {
    final json = toJsonWithMetadata();
    json['orderId'] = orderId;
    json['amount'] = amount;
    return json;
  }

  factory TestOrderEvent.fromJson(Map<String, dynamic> json) {
    final event = TestOrderEvent(
      orderId: json['orderId'] as String,
      amount: (json['amount'] as num).toDouble(),
    );
    event.fromJsonWithMetadata(json);
    return event;
  }
}

class ValidatingEvent extends TypedEvent implements TypedEventValidatable {
  final String data;

  ValidatingEvent({required this.data});

  @override
  String get type => 'validating_event';

  @override
  void validate() {
    if (data.length < 3) {
      throw ArgumentError('data must be at least 3 characters');
    }
  }

  @override
  Map<String, dynamic> toJson() => {'data': data};

  factory ValidatingEvent.fromJson(Map<String, dynamic> json) {
    return ValidatingEvent(data: json['data'] as String);
  }
}

void main() {
  group('TypedEvent', () {
    test('should create and serialize basic event', () {
      final event = TestUserEvent(userId: 'user123', action: 'login');

      expect(event.type, equals('test_user_event'));
      expect(event.userId, equals('user123'));
      expect(event.action, equals('login'));

      final json = event.toJson();
      expect(json['userId'], equals('user123'));
      expect(json['action'], equals('login'));
    });

    test('should deserialize from JSON', () {
      final json = {'userId': 'user456', 'action': 'logout'};
      final event = TestUserEvent.fromJson(json);

      expect(event.userId, equals('user456'));
      expect(event.action, equals('logout'));
      expect(event.type, equals('test_user_event'));
    });

    test('should support equality comparison', () {
      final event1 = TestUserEvent(userId: 'user1', action: 'login');
      final event2 = TestUserEvent(userId: 'user1', action: 'login');
      final event3 = TestUserEvent(userId: 'user2', action: 'login');

      expect(event1, equals(event2));
      expect(event1, isNot(equals(event3)));
    });

    test('should have consistent hash codes', () {
      final event1 = TestUserEvent(userId: 'user1', action: 'login');
      final event2 = TestUserEvent(userId: 'user1', action: 'login');

      expect(event1.hashCode, equals(event2.hashCode));
    });

    test('should provide meaningful toString', () {
      final event = TestUserEvent(userId: 'user123', action: 'login');
      final str = event.toString();

      expect(str, contains('TestUserEvent'));
      expect(str, contains('test_user_event'));
      expect(str, contains('user123'));
    });
  });

  group('TypedEventMixin', () {
    late TestOrderEvent event;

    setUp(() {
      event = TestOrderEvent(orderId: 'order123', amount: 99.99);
    });

    test('should provide creation timestamp', () {
      final before = DateTime.now();
      final createdAt = event.createdAt;
      final after = DateTime.now();

      expect(createdAt.isAfter(before.subtract(Duration(seconds: 1))), isTrue);
      expect(createdAt.isBefore(after.add(Duration(seconds: 1))), isTrue);
    });

    test('should support metadata operations', () {
      expect(event.metadata, isEmpty);

      event.setMetadata('source', 'mobile');
      event.setMetadata('version', '1.0.0');

      expect(event.getMetadata<String>('source'), equals('mobile'));
      expect(event.getMetadata<String>('version'), equals('1.0.0'));
      expect(event.getMetadata<String>('nonexistent'), isNull);
      expect(event.metadata, hasLength(2));

      final removed = event.removeMetadata('source');
      expect(removed, isTrue);
      expect(event.getMetadata<String>('source'), isNull);
      expect(event.metadata, hasLength(1));
    });

    test('should validate event data', () {
      final validEvent = TestOrderEvent(orderId: 'order123', amount: 50.0);
      expect(() => validEvent.validate(), returnsNormally);

      final invalidOrder = TestOrderEvent(orderId: '', amount: 50.0);
      expect(() => invalidOrder.validate(), throwsArgumentError);

      final invalidAmount = TestOrderEvent(orderId: 'order123', amount: -10.0);
      expect(() => invalidAmount.validate(), throwsArgumentError);
    });

    test('should serialize with metadata', () {
      event.setMetadata('source', 'web');
      final json =
          event.toJson(); // Use toJson() which includes both data and metadata

      expect(json, containsPair('orderId', 'order123'));
      expect(json, containsPair('amount', 99.99));
      expect(json, contains('createdAt'));
      expect(json, contains('metadata'));
      expect(json['metadata']['source'], equals('web'));
    });

    test('should deserialize metadata', () {
      final json = {
        'orderId': 'order456',
        'amount': 123.45,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'metadata': {'source': 'api', 'version': '2.0'},
      };

      final event = TestOrderEvent.fromJson(json);
      expect(event.getMetadata<String>('source'), equals('api'));
      expect(event.getMetadata<String>('version'), equals('2.0'));
    });

    test('should handle complex nested data in equality', () {
      final event1 = TestOrderEvent(orderId: 'order1', amount: 100.0);
      final event2 = TestOrderEvent(orderId: 'order1', amount: 100.0);

      event1.setMetadata('complex', {
        'nested': {
          'data': [1, 2, 3],
        },
      });
      event2.setMetadata('complex', {
        'nested': {
          'data': [1, 2, 3],
        },
      });

      expect(event1, equals(event2));
    });
  });

  group('TypedEventRegistry', () {
    late TypedEventRegistry registry;

    setUp(() {
      registry = TypedEventRegistry();
      registry.clear(); // Start with clean registry
    });

    tearDown(() {
      registry.clear();
    });

    test('should register and retrieve event types', () {
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );

      expect(registry.isRegistered('test_user_event'), isTrue);
      expect(registry.isRegistered('unknown_type'), isFalse);
      expect(registry.isDartTypeRegistered<TestUserEvent>(), isTrue);
      expect(registry.getType<TestUserEvent>(), equals('test_user_event'));
    });

    test('should create events from JSON', () {
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );

      final json = {'userId': 'user789', 'action': 'signup'};
      final event = registry.createFromJson('test_user_event', json);

      expect(event, isA<TestUserEvent>());
      expect((event as TestUserEvent).userId, equals('user789'));
    });

    test('should return null for unregistered types', () {
      final event = registry.createFromJson('unknown_type', {});
      expect(event, isNull);
    });

    test('should create strongly-typed events', () {
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );

      final json = {'userId': 'user999', 'action': 'delete'};
      final event = registry.createFromJsonAs<TestUserEvent>(
        'test_user_event',
        json,
      );

      expect(event, isA<TestUserEvent>());
      expect(event?.userId, equals('user999'));

      // Wrong type should return null
      final wrongType = registry.createFromJsonAs<TestOrderEvent>(
        'test_user_event',
        json,
      );
      expect(wrongType, isNull);
    });

    test('should prevent duplicate registrations with different types', () {
      registry.register<TestUserEvent>(
        'duplicate_type',
        (json) => TestUserEvent.fromJson(json),
      );

      expect(
        () => registry.register<TestOrderEvent>(
          'duplicate_type',
          (json) => TestOrderEvent.fromJson(json),
        ),
        throwsArgumentError,
      );
    });

    test('should allow re-registration of same type', () {
      registry.register<TestUserEvent>(
        'test_type',
        (json) => TestUserEvent.fromJson(json),
      );

      // Should not throw
      expect(
        () => registry.register<TestUserEvent>(
          'test_type',
          (json) => TestUserEvent.fromJson(json),
        ),
        returnsNormally,
      );
    });

    test('should validate input parameters', () {
      expect(
        () => registry.register<TestUserEvent>(
          '',
          (json) => TestUserEvent.fromJson(json),
        ),
        throwsArgumentError,
      );

      expect(() => registry.createFromJson('', {}), throwsArgumentError);
    });

    test('should provide registry statistics', () {
      registry.register<TestUserEvent>(
        'user_event',
        (json) => TestUserEvent.fromJson(json),
      );
      registry.register<TestOrderEvent>(
        'order_event',
        (json) => TestOrderEvent.fromJson(json),
      );

      final stats = registry.getStats();
      expect(stats.totalRegisteredTypes, equals(2));
      expect(stats.registeredTypes, containsAll(['user_event', 'order_event']));
      expect(stats.registeredDartTypes, hasLength(2));
    });

    test('should handle factory errors gracefully', () {
      registry.register<TestUserEvent>(
        'error_type',
        (json) => throw FormatException('Invalid JSON'),
      );

      expect(
        () => registry.createFromJson('error_type', {}),
        throwsA(isA<TypedEventRegistryException>()),
      );
    });

    test('should support unregistration', () {
      registry.register<TestUserEvent>(
        'temp_type',
        (json) => TestUserEvent.fromJson(json),
      );

      expect(registry.isRegistered('temp_type'), isTrue);

      final unregistered = registry.unregister('temp_type');
      expect(unregistered, isTrue);
      expect(registry.isRegistered('temp_type'), isFalse);

      final unregisteredAgain = registry.unregister('temp_type');
      expect(unregisteredAgain, isFalse);
    });
  });

  group('TypedGossipNode', () {
    late Map<String, MockTransport> network;
    late GossipNode node;
    late TypedEventRegistry registry;

    setUp(() async {
      network = <String, MockTransport>{};
      registry = TypedEventRegistry();
      registry.clear();

      // Register test events
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );
      registry.register<TestOrderEvent>(
        'test_order_event',
        (json) => TestOrderEvent.fromJson(json),
      );
      registry.register<ValidatingEvent>(
        'validating_event',
        (json) => ValidatingEvent.fromJson(json),
      );

      node = GossipNode(
        config: GossipConfig(nodeId: 'test-node'),
        eventStore: MemoryEventStore(),
        transport: MockTransport('test-node', network),
      );

      await node.start();
    });

    tearDown(() async {
      await node.stop();
      registry.clear();
    });

    test('should broadcast typed events', () async {
      final typedEvent = TestUserEvent(userId: 'user123', action: 'login');
      final gossipEvent = await node.broadcastTypedEvent(typedEvent);

      expect(gossipEvent.payload['type'], equals('test_user_event'));
      expect(gossipEvent.payload['data'], isA<Map<String, dynamic>>());
      expect(gossipEvent.payload['version'], equals('1.0'));

      final data = gossipEvent.payload['data'] as Map<String, dynamic>;
      expect(data['userId'], equals('user123'));
      expect(data['action'], equals('login'));
    });

    test('should broadcast multiple typed events', () async {
      final events = [
        TestUserEvent(userId: 'user1', action: 'login'),
        TestUserEvent(userId: 'user2', action: 'logout'),
      ];

      final gossipEvents = await node.broadcastTypedEvents(events);
      expect(gossipEvents, hasLength(2));

      for (final event in gossipEvents) {
        expect(event.payload['type'], equals('test_user_event'));
      }
    });

    test('should validate events before broadcasting', () async {
      final invalidEvent = ValidatingEvent(data: 'ab'); // Too short

      expect(
        () => node.broadcastTypedEvent(invalidEvent),
        throwsA(isA<TypedEventException>()),
      );
    });

    test('should filter typed events by type', () async {
      final receivedEvents = <TestUserEvent>[];
      final subscription = node
          .onTypedEvent<TestUserEvent>((json) => TestUserEvent.fromJson(json))
          .listen(receivedEvents.add);

      // Create a second node to send events to our test node
      final senderNode = GossipNode(
        config: GossipConfig(nodeId: 'sender-node'),
        eventStore: MemoryEventStore(),
        transport: MockTransport('sender-node', network),
      );
      await senderNode.start();

      // Connect the nodes
      node.addPeer(
          GossipPeer(id: 'sender-node', address: 'mock://sender-node'));
      senderNode
          .addPeer(GossipPeer(id: 'test-node', address: 'mock://test-node'));

      // Broadcast different types of events from sender
      await senderNode.broadcastTypedEvent(
        TestUserEvent(userId: 'user1', action: 'login'),
      );
      await senderNode.broadcastTypedEvent(
        TestOrderEvent(orderId: 'order1', amount: 100.0),
      );
      await senderNode.broadcastTypedEvent(
        TestUserEvent(userId: 'user2', action: 'logout'),
      );

      // Trigger gossip to propagate events
      await senderNode.gossip();
      await Future.delayed(Duration(milliseconds: 100));

      // Should only receive user events
      expect(receivedEvents, hasLength(2));
      expect(receivedEvents[0].userId, equals('user1'));
      expect(receivedEvents[1].userId, equals('user2'));

      await subscription.cancel();
      await senderNode.stop();
    });

    test('should use registry for automatic deserialization', () async {
      final receivedEvents = <TestOrderEvent>[];
      final subscription = node.onRegisteredTypedEvent<TestOrderEvent>().listen(
            receivedEvents.add,
          );

      // Create a second node to send events
      final senderNode = GossipNode(
        config: GossipConfig(nodeId: 'sender-node2'),
        eventStore: MemoryEventStore(),
        transport: MockTransport('sender-node2', network),
      );
      await senderNode.start();

      // Connect the nodes
      node.addPeer(
          GossipPeer(id: 'sender-node2', address: 'mock://sender-node2'));
      senderNode
          .addPeer(GossipPeer(id: 'test-node', address: 'mock://test-node'));

      await senderNode.broadcastTypedEvent(
        TestOrderEvent(orderId: 'order123', amount: 99.99),
      );

      // Trigger gossip to propagate events
      await senderNode.gossip();
      await Future.delayed(Duration(milliseconds: 100));

      expect(receivedEvents, hasLength(1));
      expect(receivedEvents.first.orderId, equals('order123'));

      await subscription.cancel();
      await senderNode.stop();
    });

    test('should throw for unregistered types in registry stream', () {
      registry.unregister('test_order_event');

      expect(
        () => node.onRegisteredTypedEvent<TestOrderEvent>(),
        throwsA(isA<TypedEventException>()),
      );
    });

    test('should emit any typed events', () async {
      final receivedEvents = <TypedReceivedEvent>[];
      final subscription = node.onAnyTypedEvent().listen(receivedEvents.add);

      // Create a second node to send events
      final senderNode = GossipNode(
        config: GossipConfig(nodeId: 'sender-node3'),
        eventStore: MemoryEventStore(),
        transport: MockTransport('sender-node3', network),
      );
      await senderNode.start();

      // Connect the nodes
      node.addPeer(
          GossipPeer(id: 'sender-node3', address: 'mock://sender-node3'));
      senderNode
          .addPeer(GossipPeer(id: 'test-node', address: 'mock://test-node'));

      await senderNode.broadcastTypedEvent(
        TestUserEvent(userId: 'user1', action: 'login'),
      );
      await senderNode.broadcastTypedEvent(
        TestOrderEvent(orderId: 'order1', amount: 50.0),
      );

      // Trigger gossip to propagate events
      await senderNode.gossip();
      await Future.delayed(Duration(milliseconds: 100));

      expect(receivedEvents, hasLength(2));
      expect(receivedEvents[0].eventType, equals('test_user_event'));
      expect(receivedEvents[1].eventType, equals('test_order_event'));

      await subscription.cancel();
      await senderNode.stop();
    });

    test('should handle serialization errors gracefully', () async {
      // Create an event that will fail serialization
      final badEvent = _BadSerializationEvent();

      expect(
        () => node.broadcastTypedEvent(badEvent),
        throwsA(isA<TypedEventException>()),
      );
    });
  });

  group('TypedEventTransformer', () {
    late StreamController<Event> eventController;

    setUp(() {
      eventController = StreamController<Event>();
    });

    tearDown(() async {
      await eventController.close();
    });

    test('should transform events to typed events', () async {
      final transformer = TypedEventTransformer<TestUserEvent>(
        eventType: 'test_user_event',
        factory: (json) => TestUserEvent.fromJson(json),
      );

      final typedEventStream = eventController.stream.transform(transformer);
      final receivedEvents = <TestUserEvent>[];
      final subscription = typedEventStream.listen(receivedEvents.add);

      // Add a matching event
      final matchingEvent = Event(
        id: 'test1',
        nodeId: 'node1',
        timestamp: 1,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'test_user_event',
          'data': {'userId': 'user1', 'action': 'login'},
        },
      );

      // Add a non-matching event
      final nonMatchingEvent = Event(
        id: 'test2',
        nodeId: 'node1',
        timestamp: 2,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'other_event',
          'data': {'some': 'data'},
        },
      );

      eventController.add(matchingEvent);
      eventController.add(nonMatchingEvent);

      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedEvents, hasLength(1));
      expect(receivedEvents.first.userId, equals('user1'));

      await subscription.cancel();
    });

    test('should handle deserialization errors', () async {
      var errorCount = 0;
      final transformer = TypedEventTransformer<TestUserEvent>(
        eventType: 'test_user_event',
        factory: (json) => throw FormatException('Bad data'),
        onError: (event, error, stackTrace) {
          errorCount++;
        },
      );

      final typedEventStream = eventController.stream.transform(transformer);
      final receivedEvents = <TestUserEvent>[];
      final subscription = typedEventStream.listen(receivedEvents.add);

      final badEvent = Event(
        id: 'bad',
        nodeId: 'node1',
        timestamp: 1,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'test_user_event',
          'data': {'invalid': 'data'},
        },
      );

      eventController.add(badEvent);
      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedEvents, isEmpty);
      expect(errorCount, equals(1));

      await subscription.cancel();
    });

    test('should use registry for transformation', () async {
      final registry = TypedEventRegistry();
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );

      final transformer = RegistryTypedEventTransformer<TestUserEvent>(
        registry: registry,
      );

      final typedEventStream = eventController.stream.transform(transformer);
      final receivedEvents = <TestUserEvent>[];
      final subscription = typedEventStream.listen(receivedEvents.add);

      final event = Event(
        id: 'test',
        nodeId: 'node1',
        timestamp: 1,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'test_user_event',
          'data': {'userId': 'user123', 'action': 'login'},
        },
      );

      eventController.add(event);
      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedEvents, hasLength(1));
      expect(receivedEvents.first.userId, equals('user123'));

      await subscription.cancel();
      registry.clear();
    });

    test('should handle multiple event types', () async {
      final registry = TypedEventRegistry();
      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );
      registry.register<TestOrderEvent>(
        'test_order_event',
        (json) => TestOrderEvent.fromJson(json),
      );

      final transformer = MultiTypeEventTransformer(
        registry: registry,
        includeTypes: {'test_user_event', 'test_order_event'},
      );

      final typedEventStream = eventController.stream.transform(transformer);
      final receivedEvents = <TypedEvent>[];
      final subscription = typedEventStream.listen(receivedEvents.add);

      final userEvent = Event(
        id: 'user1',
        nodeId: 'node1',
        timestamp: 1,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'test_user_event',
          'data': {'userId': 'user1', 'action': 'login'},
        },
      );

      final orderEvent = Event(
        id: 'order1',
        nodeId: 'node1',
        timestamp: 2,
        creationTimestamp: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'type': 'test_order_event',
          'data': {
            'orderId': 'order1',
            'amount': 100.0,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          },
        },
      );

      eventController.add(userEvent);
      eventController.add(orderEvent);
      await Future.delayed(Duration(milliseconds: 50));

      expect(receivedEvents, hasLength(2));
      expect(receivedEvents[0], isA<TestUserEvent>());
      expect(receivedEvents[1], isA<TestOrderEvent>());

      await subscription.cancel();
      registry.clear();
    });
  });

  group('Integration Tests', () {
    late Map<String, MockTransport> network;
    late List<GossipNode> nodes;
    late TypedEventRegistry registry;

    setUp(() async {
      network = <String, MockTransport>{};
      registry = TypedEventRegistry();
      registry.clear();

      registry.register<TestUserEvent>(
        'test_user_event',
        (json) => TestUserEvent.fromJson(json),
      );

      nodes = [
        GossipNode(
          config: GossipConfig(nodeId: 'node1'),
          eventStore: MemoryEventStore(),
          transport: MockTransport('node1', network),
        ),
        GossipNode(
          config: GossipConfig(nodeId: 'node2'),
          eventStore: MemoryEventStore(),
          transport: MockTransport('node2', network),
        ),
      ];

      await Future.wait(nodes.map((node) => node.start()));

      // Connect nodes
      nodes[0].addPeer(GossipPeer(id: 'node2', address: 'mock://node2'));
      nodes[1].addPeer(GossipPeer(id: 'node1', address: 'mock://node1'));
    });

    tearDown(() async {
      await Future.wait(nodes.map((node) => node.stop()));
      registry.clear();
    });

    test('should propagate typed events between nodes', () async {
      final receivedEvents = <TestUserEvent>[];
      final subscription = nodes[1]
          .onRegisteredTypedEvent<TestUserEvent>()
          .listen(receivedEvents.add);

      // Create event on node 1
      final event = TestUserEvent(userId: 'distributed_user', action: 'test');
      await nodes[0].broadcastTypedEvent(event);

      // Trigger gossip
      await nodes[0].gossip();
      await Future.delayed(Duration(milliseconds: 100));

      // Should receive on node 2
      expect(receivedEvents, hasLength(1));
      expect(receivedEvents.first.userId, equals('distributed_user'));

      await subscription.cancel();
    });

    test('should maintain event metadata across network', () async {
      final receivedEvents = <TestOrderEvent>[];

      registry.register<TestOrderEvent>(
        'test_order_event',
        (json) => TestOrderEvent.fromJson(json),
      );

      final subscription = nodes[1]
          .onRegisteredTypedEvent<TestOrderEvent>()
          .listen(receivedEvents.add);

      // Create event with metadata
      final event = TestOrderEvent(orderId: 'meta_order', amount: 199.99);
      event.setMetadata('source', 'integration_test');
      event.setMetadata('priority', 'high');

      await nodes[0].broadcastTypedEvent(event);
      await nodes[0].gossip();
      await Future.delayed(Duration(milliseconds: 100));

      expect(receivedEvents, hasLength(1));
      final received = receivedEvents.first;
      expect(received.orderId, equals('meta_order'));
      expect(
        received.getMetadata<String>('source'),
        equals('integration_test'),
      );
      expect(received.getMetadata<String>('priority'), equals('high'));

      await subscription.cancel();
    });
  });
}

/// Helper class for testing serialization errors
class _BadSerializationEvent extends TypedEvent {
  @override
  String get type => 'bad_event';

  @override
  Map<String, dynamic> toJson() {
    throw Exception('Serialization failed');
  }
}
