////////////////////////////////////////////////////////////////////////////////
//
// Copyright 2023 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////////

import 'package:test/expect.dart' hide throws;

import '../lib/realm.dart';
import 'test.dart';

part 'asymmetric_test.g.dart';

@RealmModel(ObjectType.asymmetricObject)
class _Asymmetric {
  @PrimaryKey()
  @MapTo('_id')
  late ObjectId id;

  late List<_Embedded> embeddedObjects;
}

@RealmModel(ObjectType.embeddedObject)
class _Embedded {
  late int value;
  late RealmValue any;
  _Symmetric? symmetric;
}

@RealmModel()
class _Symmetric {
  @PrimaryKey()
  @MapTo('_id')
  late ObjectId id;
}

Future<void> main([List<String>? args]) async {
  await setupTests(args);

  Future<Realm> getSyncRealm(AppConfiguration config) async {
    final app = App(config);
    final user = await getAnonymousUser(app);
    final realmConfig = Configuration.flexibleSync(user, [Asymmetric.schema, Embedded.schema, Symmetric.schema]);
    return getRealm(realmConfig);
  }

  baasTest('Asymmetric objects die even before upload', (config) async {
    final realm = await getSyncRealm(config);
    realm.syncSession.pause();

    final oid = ObjectId();
    realm.write(() {
      realm.ingest(Asymmetric(oid, embeddedObjects: [1, 2, 3].map(Embedded.new)));
    });

    // Find & query on an Asymmetric object is compile time error, but you can cheat with dynamic
    expect(realm.dynamic.find('Asymmetric', oid), null);
    expect(() => realm.dynamic.all('Asymmetric'), throws<RealmException>('Query on ephemeral objects not allowed'));

    realm.syncSession.resume();
    await realm.syncSession.waitForUpload();
  });

  baasTest('Asymmetric re-add same PK', (config) async {
    final realm = await getSyncRealm(config);

    final oid = ObjectId();
    realm.write(() {
      realm.ingest(Asymmetric(oid, embeddedObjects: [1, 2, 3].map(Embedded.new)));
      expect(() => realm.ingest(Asymmetric(oid, embeddedObjects: [1, 2, 3, 4].map(Embedded.new))),
          throws<RealmException>("Attempting to create an object of type 'Asymmetric' with an existing primary key value"));
    });

    realm.write(() {
      // okay to ingest again in another transaction, because object already dead to us
      realm.ingest(Asymmetric(oid, embeddedObjects: [1, 2, 3, 5].map(Embedded.new)));
    });

    await realm.syncSession.waitForUpload();
  });

  baasTest('Asymmetric tricks to add non-embedded links', (config) async {
    final realm = await getSyncRealm(config);

    realm.subscriptions.update((mutableSubscriptions) {
      mutableSubscriptions.add(realm.all<Symmetric>());
    });

    realm.write(() {
      final s = realm.add(Symmetric(ObjectId()));
      // Since this shenanigan is allowed, I have opened a feature request to allow
      // direct links on a symmetric objects. See https://github.com/realm/realm-core/issues/6976.
      realm.ingest(Asymmetric(ObjectId(), embeddedObjects: [Embedded(1, symmetric: s)]));
      realm.ingest(Asymmetric(ObjectId(), embeddedObjects: [Embedded(1, any: RealmValue.from(s))]));
    });

    await realm.syncSession.waitForUpload();
  });

  test("Asymmetric don't work local realms", () {
    expect(() => Realm(Configuration.local([Asymmetric.schema, Embedded.schema, Symmetric.schema])),
        throws<RealmException>("Asymmetric table 'Asymmetric' not allowed in a local Realm"));
  });

  test("Asymmetric don't work with disconnectedSync", () {
    final config = Configuration.disconnectedSync([Asymmetric.schema, Embedded.schema, Symmetric.schema], path: 'asymmetric_disconnected.realm');
    expect(() => Realm(config), throws<RealmException>());
  });

  // TODO
  // Test that asymmetric objects are actually transferred to backend, once we have
  // a mongoClient to query the backend with.
}
