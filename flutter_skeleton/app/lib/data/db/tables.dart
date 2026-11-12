import 'package:drift/drift.dart';

/// Mirrors `ChatStore+Schema.swift` exactly. Column names and types must stay
/// byte-compatible with the Swift app so a legacy minis.db can be read as-is.
class Sessions extends Table {
  @override
  String get tableName => 'sessions';

  TextColumn get id => text()();
  TextColumn get title => text().nullable()();
  TextColumn get modelId => text()();
  RealColumn get createdAt => real()();
  RealColumn get updatedAt => real()();
  TextColumn get parentSessionId => text().nullable()();
  TextColumn get parentToolUseId => text().nullable()();
  TextColumn get previewText => text().nullable()();
  IntColumn get previewSortOrder => integer().nullable()();
  RealColumn get remoteTombstonedAt => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  @override
  String get tableName => 'messages';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()();
  TextColumn get partsJson => text()();
  RealColumn get createdAt => real()();
  TextColumn get tokenUsage => text().nullable()();
  IntColumn get sortOrder => integer()();
  RealColumn get updatedAt => real().nullable()();
  TextColumn get errorInfo => text().nullable()();
  IntColumn get partFlags => integer().withDefault(const Constant(0))();
  TextColumn get modelId => text().nullable()();
  TextColumn get modelDisplayName => text().nullable()();
  TextColumn get providerType => text().nullable()();
  TextColumn get providerInstanceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Folders extends Table {
  @override
  String get tableName => 'folders';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get icon => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get origin => text().withDefault(const Constant('manual'))();
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();
  RealColumn get pinnedAt => real().nullable()();
  TextColumn get description => text().nullable()();
  RealColumn get createdAt => real()();
  RealColumn get updatedAt => real()();

  @override
  Set<Column> get primaryKey => {id};
}
