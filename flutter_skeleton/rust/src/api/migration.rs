//! Migration verification lives in Rust: it is pure logic over counts and
//! field samples, exactly the kind of work that should not be duplicated in
//! Dart and Swift with subtly different rules.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TableCount {
    pub table: String,
    pub legacy: i64,
    pub migrated: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MigrationReport {
    pub ok: bool,
    pub total_legacy: i64,
    pub total_migrated: i64,
    /// Tables whose counts differ — empty when `ok`.
    pub mismatched_tables: Vec<String>,
}

/// Compare per-table row counts. `ok` requires an exact match on every table:
/// partial migration is a failure, not a warning.
pub fn verify_migration(counts: Vec<TableCount>) -> MigrationReport {
    let mut mismatched = Vec::new();
    let mut total_legacy = 0i64;
    let mut total_migrated = 0i64;

    for c in &counts {
        total_legacy += c.legacy;
        total_migrated += c.migrated;
        if c.legacy != c.migrated {
            mismatched.push(c.table.clone());
        }
    }

    MigrationReport {
        ok: mismatched.is_empty(),
        total_legacy,
        total_migrated,
        mismatched_tables: mismatched,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(table: &str, legacy: i64, migrated: i64) -> TableCount {
        TableCount { table: table.into(), legacy, migrated }
    }

    #[test]
    fn exact_match_is_ok() {
        let r = verify_migration(vec![c("sessions", 12, 12), c("messages", 340, 340)]);
        assert!(r.ok);
        assert_eq!(r.total_legacy, 352);
        assert!(r.mismatched_tables.is_empty());
    }

    #[test]
    fn missing_rows_are_reported() {
        let r = verify_migration(vec![c("sessions", 12, 12), c("messages", 340, 339)]);
        assert!(!r.ok);
        assert_eq!(r.mismatched_tables, vec!["messages".to_string()]);
    }
}
