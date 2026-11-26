import os
import shutil
import sqlite3
import sys
import tempfile


def copy_with_wal(src_db: str, dst_db: str) -> None:
    shutil.copy2(src_db, dst_db)
    for suffix in ("-wal", "-shm"):
        src_sidecar = src_db + suffix
        if os.path.exists(src_sidecar):
            shutil.copy2(src_sidecar, dst_db + suffix)


def get_columns(cur: sqlite3.Cursor, table: str) -> list[str]:
    return [row[1] for row in cur.execute(f'PRAGMA table_info("{table}")').fetchall()]


def table_exists(cur: sqlite3.Cursor, table: str) -> bool:
    row = cur.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
        (table,),
    ).fetchone()
    return row is not None


def merge_databases(backup_db: str, target_db: str) -> None:
    if not os.path.exists(backup_db):
        raise FileNotFoundError(f"Backup DB not found: {backup_db}")
    if not os.path.exists(target_db):
        copy_with_wal(backup_db, target_db)
        con = sqlite3.connect(target_db)
        con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        total = con.execute("SELECT COUNT(*) FROM conversation_summaries").fetchone()[0]
        fts = con.execute("SELECT COUNT(*) FROM conversations_fts").fetchone()[0]
        con.close()
        print(f"merged_added={total} merged_updated=0 total_rows={total} fts_rows={fts}")
        return

    tmp_dir = tempfile.mkdtemp(prefix="agy_merge_")
    try:
        tmp_backup_db = os.path.join(tmp_dir, "backup.db")
        copy_with_wal(backup_db, tmp_backup_db)

        b_con = sqlite3.connect(tmp_backup_db)
        b_con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        b_cur = b_con.cursor()

        t_con = sqlite3.connect(target_db)
        t_con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        t_cur = t_con.cursor()

        sum_cols = get_columns(t_cur, "conversation_summaries")
        b_sum_cols = get_columns(b_cur, "conversation_summaries")
        common_sum_cols = [c for c in sum_cols if c in b_sum_cols]
        col_list_sql = ", ".join(f'"{c}"' for c in common_sum_cols)
        placeholders_sql = ", ".join("?" for _ in common_sum_cols)

        id_idx = common_sum_cols.index("conversation_id")
        mtime_idx = common_sum_cols.index("last_modified_time")

        existing_mtimes = {
            row[0]: row[1]
            for row in t_cur.execute(
                "SELECT conversation_id, last_modified_time FROM conversation_summaries"
            ).fetchall()
        }

        has_fts = table_exists(b_cur, "conversations_fts") and table_exists(
            t_cur, "conversations_fts"
        )
        common_fts_cols: list[str] = []
        if has_fts:
            t_fts_cols = get_columns(t_cur, "conversations_fts")
            b_fts_cols = get_columns(b_cur, "conversations_fts")
            common_fts_cols = [c for c in t_fts_cols if c in b_fts_cols]
            fts_cols_sql = ", ".join(f'"{c}"' for c in common_fts_cols)
            fts_ph_sql = ", ".join("?" for _ in common_fts_cols)

        has_parents = table_exists(b_cur, "conversation_parents") and table_exists(
            t_cur, "conversation_parents"
        )

        added = 0
        updated = 0
        backup_rows = b_cur.execute(
            f"SELECT {col_list_sql} FROM conversation_summaries"
        ).fetchall()

        for row in backup_rows:
            cid = row[id_idx]
            b_mtime = row[mtime_idx] or ""
            t_mtime = existing_mtimes.get(cid)

            if t_mtime is None:
                added += 1
            elif b_mtime > t_mtime:
                updated += 1
            else:
                continue

            t_cur.execute(
                f"INSERT OR REPLACE INTO conversation_summaries ({col_list_sql}) VALUES ({placeholders_sql})",
                row,
            )

            if has_fts and common_fts_cols:
                t_cur.execute(
                    "DELETE FROM conversations_fts WHERE conversation_id = ?", (cid,)
                )
                fts_rows = b_cur.execute(
                    f"SELECT {fts_cols_sql} FROM conversations_fts WHERE conversation_id = ?",
                    (cid,),
                ).fetchall()
                if fts_rows:
                    t_cur.executemany(
                        f"INSERT INTO conversations_fts ({fts_cols_sql}) VALUES ({fts_ph_sql})",
                        fts_rows,
                    )

            if has_parents:
                parent_row = b_cur.execute(
                    "SELECT conversation_id, parent_id FROM conversation_parents WHERE conversation_id = ?",
                    (cid,),
                ).fetchone()
                if parent_row:
                    t_cur.execute(
                        "INSERT OR REPLACE INTO conversation_parents (conversation_id, parent_id) VALUES (?, ?)",
                        parent_row,
                    )

        t_con.commit()
        t_con.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        total = t_cur.execute("SELECT COUNT(*) FROM conversation_summaries").fetchone()[0]
        fts_total = (
            t_cur.execute("SELECT COUNT(*) FROM conversations_fts").fetchone()[0]
            if has_fts
            else 0
        )

        b_con.close()
        t_con.close()
        print(
            f"merged_added={added} merged_updated={updated} total_rows={total} fts_rows={fts_total}"
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: merge_summaries.py <backup_db_path> <target_db_path>",
            file=sys.stderr,
        )
        return 2
    merge_databases(sys.argv[1], sys.argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
