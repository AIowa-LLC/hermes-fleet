import Foundation
import SwiftData

/// Version 1.0.0 of the on-device cache schema: a pure snapshot of the models
/// that shipped before versioning existed (build 96 and earlier). It lists
/// exactly the same entities as the old flat `ModelContainer(for:)` call, so
/// an existing store's model hashes match V1 and it opens in place with no
/// migration and no data change.
///
/// **Schema-change rule (see docs/DEVELOPMENT.md):** any change to a `@Model`
/// (add/remove/rename a model or stored property, change a type, change a
/// uniqueness constraint) requires a new `FleetSchemaVN`, appended to
/// `FleetMigrationPlan.schemas`, and a `MigrationStage` connecting the
/// previous version to it. Before editing a model, freeze the previous shape
/// as nested `@Model` copies inside the old `VersionedSchema` (V1 currently
/// references the live top-level classes, which is only correct while they
/// are unchanged).
public enum FleetSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            CachedMessageRow.self,
            CachedWatermarkRow.self,
            CachedReplayEpochRow.self,
            CachedHealthStatsRow.self,
            CachedGatewayRow.self,
            LearningGraphSnapshotRow.self,
            ProjectsSnapshotRow.self,
            // ADR-0012 launch cache rides the same container (the app hands
            // `SwiftDataLaunchCacheStore(container:)` the shared one), so its
            // row models must be in the schema or fetches on them fail.
            LaunchRosterRow.self,
            LaunchSessionListRow.self,
        ]
    }
}

/// The migration plan for the cache store. V1 is the only version, so there
/// are no stages. New versions append to `schemas` and add a stage.
public enum FleetMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [FleetSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

extension ModelContainer {
    /// Builds the cache container through the versioned schema + migration plan.
    static func fleetCache(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: FleetSchemaV1.self),
            migrationPlan: FleetMigrationPlan.self,
            configurations: configuration
        )
    }
}
