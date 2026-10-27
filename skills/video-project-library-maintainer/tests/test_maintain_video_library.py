import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "scripts" / "maintain_video_library.py"
SPEC = importlib.util.spec_from_file_location("maintainer", SCRIPT)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)


class MaintainerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.library = self.root / "library"
        (self.library / "项目").mkdir(parents=True)
        (self.library / "资料库管理").mkdir()
        self.source = self.root / "source"
        self.source.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, data=b"x"):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_every_file_has_one_concrete_category(self):
        self.write("脚本/script.txt", "正文".encode("utf-8"))
        self.write("raw/camera.mp4", b"\0\0\0\x18ftypmp42")
        self.write("cache/blob.weird", b"\x00\x01\x02")
        self.write("plugin.dll", b"MZ\x00\x03\x04")
        records, _ = MOD.scan(self.source)
        check = MOD.gate(records, MOD.count_files(self.source))
        self.assertTrue(check["passed"])
        self.assertEqual(len(records), 4)
        for item in records:
            combined = item["primary_category"] + item["subcategory"]
            self.assertFalse(any(word in combined.lower() for word in MOD.FORBIDDEN_CLASS_WORDS))
        blob = next(item for item in records if item["relative_path"] == "cache/blob.weird")
        self.assertEqual(blob["subcategory"], "工程数据或缓存")
        plugin = next(item for item in records if item["relative_path"] == "plugin.dll")
        self.assertEqual(plugin["subcategory"], "工程辅助二进制文件")

    def test_forbidden_category_fails_gate(self):
        item = {"relative_path": "a", "primary_category": "待分类", "subcategory": "空", "classification_basis": ["x"], "confidence": "low"}
        self.assertFalse(MOD.gate([item], 1)["passed"])

    def test_media_inside_review_folder_remains_media(self):
        image = MOD.classify(Path("visuals/review/cover.png"), "png", None)
        video = MOD.classify(Path("publish/review-v1/final.mp4"), "iso-media", None)
        report = MOD.classify(Path("visuals/review/quality.json"), "text-data", None)
        self.assertEqual(image["primary_category"], "02_工程源文件/02_原始图片")
        self.assertEqual(video["primary_category"], "02_工程源文件/08_平台发布包")
        self.assertEqual(report["primary_category"], "03_机器清单_勿手改/05_质检报告")

    def test_register_refresh_preserves_source_and_is_idempotent(self):
        source_file = self.write("文案/script.txt", "版本一".encode("utf-8"))
        before = MOD.digest(source_file)
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="测试项目", library_root=str(self.library), apply=True)
        MOD.register(args)
        project = self.library / "项目" / "测试项目"
        MOD.refresh(SimpleNamespace(project_root=str(project), apply=True))
        self.assertEqual(before, MOD.digest(source_file))
        copies = list((project / "01_给Codex审核/当前正式版/02_文案与分镜").rglob("script*"))
        self.assertEqual(len(copies), 1)
        machine = project / "03_机器清单_勿手改"
        self.assertTrue((machine / "04_来源与交接/source-provenance.json").is_file())
        self.assertTrue((machine / "04_来源与交接/automation-handoff.json").is_file())
        self.assertTrue((machine / "05_质检报告/classification-qc.json").is_file())
        self.assertTrue(MOD.verify(SimpleNamespace(project_root=str(project)))["ok"])

    def test_same_name_new_content_keeps_both(self):
        source_file = self.write("文案/script.txt", b"one")
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="碰撞项目", library_root=str(self.library), apply=True)
        MOD.register(args)
        project = self.library / "项目/碰撞项目"
        source_file.write_bytes(b"two")
        MOD.refresh(SimpleNamespace(project_root=str(project), apply=True))
        files = list((project / "01_给Codex审核/当前正式版/02_文案与分镜").rglob("script.txt"))
        self.assertEqual(len(files), 1)
        self.assertEqual(b"two", files[0].read_bytes())

    def test_large_review_media_is_not_copied(self):
        self.write("final/final.mp4", b"\0\0\0\x18ftypmp42")
        records, _ = MOD.scan(self.source)
        records[0]["size_bytes"] = MOD.COPY_LIMIT + 1
        self.assertIsNone(MOD.review_target(self.library / "项目/x", records[0]))

    def test_unreadable_is_classified(self):
        item = MOD.classify(Path("broken.bin"), "unreadable-file", "PermissionError: denied")
        self.assertEqual(item["primary_category"], "02_工程源文件/09_备份与历史版本")
        self.assertEqual(item["subcategory"], "损坏或不可读文件")

    def test_link_is_rejected(self):
        self.write("asset.txt")
        with mock.patch.object(MOD, "is_link", side_effect=lambda p: Path(p).name == "asset.txt"):
            with self.assertRaises(MOD.GateError):
                MOD.scan(self.source)

    def test_path_traversal_name_is_rejected(self):
        with self.assertRaises(MOD.GateError):
            MOD.legal_name("../escape")

    def test_windows_reserved_project_name_is_rejected(self):
        for name in ("CON", "nul.txt", "LPT9"):
            with self.subTest(name=name), self.assertRaises(MOD.GateError):
                MOD.legal_name(name)

    def test_ancestor_reparse_point_is_rejected(self):
        nested = self.source / "nested"
        nested.mkdir()
        original = MOD.is_link
        with mock.patch.object(MOD, "is_link", side_effect=lambda path: Path(path) == self.source or original(Path(path))):
            with self.assertRaises(MOD.GateError):
                MOD.plain_dir(nested, "测试目录")

    def test_preview_does_not_write(self):
        self.write("script.txt", b"text")
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="预演项目", library_root=str(self.library), apply=False)
        result = MOD.register(args)
        self.assertEqual(result["mode"], "preview")
        self.assertFalse((self.library / "项目/预演项目").exists())

    def test_existing_unmanaged_project_is_rejected(self):
        self.write("script.txt", b"text")
        (self.library / "项目/非受管项目").mkdir()
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="非受管项目", library_root=str(self.library), apply=False)
        with self.assertRaises(MOD.GateError):
            MOD.register(args)

    def test_existing_lock_blocks_apply_without_writes(self):
        self.write("script.txt", b"text")
        lock = self.library / "项目/.锁项目.video-project-library.lock"
        lock.write_text("busy", encoding="utf-8")
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="锁项目", library_root=str(self.library), apply=True)
        with self.assertRaises(MOD.GateError):
            MOD.register(args)
        self.assertFalse((self.library / "项目/锁项目").exists())

    def test_source_change_after_preview_blocks_apply(self):
        source_file = self.write("script.txt", b"one")
        project = self.library / "项目/变化项目"
        payload = MOD.preview(self.source, [], project, "变化项目")
        source_file.write_bytes(b"two")
        with self.assertRaises(MOD.GateError):
            MOD.apply_project(project, self.source, "变化项目", payload)
        self.assertFalse(project.exists())

    def test_curated_review_sources_control_human_view(self):
        self.write("history/cover-old.png", b"\x89PNG\r\n\x1a\nold")
        curated = self.root / "curated"
        curated.mkdir()
        (curated / "cover-final.png").write_bytes(b"\x89PNG\r\n\x1a\nfinal")
        args = SimpleNamespace(source=str(self.source), review_source=[str(curated)], project_name="精炼项目", library_root=str(self.library), apply=True)
        MOD.register(args)
        review = self.library / "项目/精炼项目/01_给Codex审核/当前正式版/03_图片与封面"
        self.assertEqual(1, len(list(review.rglob("cover-final.png"))))
        self.assertEqual(0, len(list(review.rglob("cover-old.png"))))

    def test_curated_source_folder_purpose_controls_review_destination(self):
        scripts = self.root / "1.脚本" / "episode"
        reports = self.root / "4.报告" / "episode"
        scripts.mkdir(parents=True)
        reports.mkdir(parents=True)
        (scripts / "口播稿.txt").write_text("正文", encoding="utf-8")
        (reports / "验收清单.json").write_text("{}", encoding="utf-8")
        args = SimpleNamespace(
            source=str(self.source),
            review_source=[str(scripts), str(reports)],
            project_name="用途项目",
            library_root=str(self.library),
            apply=True,
        )
        MOD.register(args)
        review = self.library / "项目/用途项目/01_给Codex审核/当前正式版"
        self.assertEqual(1, len(list((review / "02_文案与分镜").rglob("口播稿.txt"))))
        self.assertEqual(1, len(list((review / "07_问题与修改记录").rglob("验收清单.json"))))

    def test_curated_output_separates_preview_and_explicit_final_masters(self):
        output = self.root / "output"
        output.mkdir()
        (output / "master-vertical.mp4").write_bytes(b"\0\0\0\x18ftypmp42")
        (output / "master-vertical-final.mp4").write_bytes(b"\0\0\0\x18ftypmp42-final")
        records, review_records, _, _ = MOD.scan_source_set(self.source, [output])
        destinations = {
            Path(item["source_path"]).name: item["review_destination"]
            for item in review_records
            if item["source_role"].startswith("review-")
        }
        self.assertEqual(destinations["master-vertical.mp4"], "05_预览片")
        self.assertEqual(destinations["master-vertical-final.mp4"], "06_最终成片")

    def make_final_delivery(self, *, stale=False, large=False):
        script = self.write("input/script.txt", "定稿".encode("utf-8"))
        plan = self.write("shot-plan-v4.json", b"{}")
        master = self.write("output/master-v4.mp4", b"\0\0\0\x18ftypmp42-final")
        if large:
            master.write_bytes(b"x" * 128)
        cover = self.write("platform-packages-v4/douyin/cover.png", b"\x89PNG\r\n\x1a\ncover")
        package = self.write("platform-packages-v4/package-manifest.json", b"{}")
        episode = self.write("episode-manifest-v4.json", b"{}")
        receipt = self.write("reports/automated-edit-run-v4.json", b'{"status":"passed"}')
        delivery = {
            "schema_version": "1.0", "status": "passed", "generated_at": "2026-10-15T14:00:00+00:00",
            "episode_manifest": {"path": "episode-manifest-v4.json", "sha256": MOD.digest(episode), "size": episode.stat().st_size},
            "bindings": {
                "script": {"path": "input/script.txt", "sha256": MOD.digest(script), "size": script.stat().st_size},
                "plan": {"path": "shot-plan-v4.json", "sha256": MOD.digest(plan), "size": plan.stat().st_size},
                "master_vertical": {"path": "output/master-v4.mp4", "sha256": MOD.digest(master), "size": master.stat().st_size},
                "platform_package_manifest": {"path": "platform-packages-v4/package-manifest.json", "sha256": MOD.digest(package), "size": package.stat().st_size},
                "report_pipeline_render_receipt": {"path": "reports/automated-edit-run-v4.json", "sha256": MOD.digest(receipt), "size": receipt.stat().st_size},
            },
            "publication_performed": False,
        }
        for platform in ("wechat_channels", "douyin", "xiaohongshu", "bilibili"):
            delivery["bindings"][f"platform_{platform}_master"] = {
                "path": "output/master-v4.mp4", "sha256": MOD.digest(master), "size": master.stat().st_size,
            }
            delivery["bindings"][f"platform_{platform}_cover"] = {
                "path": "platform-packages-v4/douyin/cover.png", "sha256": MOD.digest(cover), "size": cover.stat().st_size,
            }
        if stale:
            delivery["bindings"]["report_pipeline_render_receipt"]["sha256"] = "0" * 64
        path = self.source / "delivery/final-delivery-v4.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(delivery, ensure_ascii=False), encoding="utf-8")
        return path

    def test_engineering_index_does_not_double_count_nested_review_sources(self):
        self.write("input/script.txt", b"text")
        records, review_records, _, source_count = MOD.scan_source_set(self.source, [self.source / "input"])
        self.assertEqual(1, source_count)
        self.assertEqual(1, len(records))
        self.assertEqual(1, len(review_records))
        self.assertEqual("engineering/input/script.txt", records[0]["relative_path"])

    def test_final_delivery_drives_current_view_preserves_paths_and_bypasses_size_cap(self):
        self.make_final_delivery(large=True)
        with mock.patch.object(MOD, "COPY_LIMIT", 32):
            args = SimpleNamespace(source=str(self.source), review_source=[], project_name="正式版项目", library_root=str(self.library), apply=True)
            result = MOD.register(args)
        self.assertIsInstance(MOD.dump(result), str)
        project = self.library / "项目/正式版项目"
        current = project / "01_给Codex审核/当前正式版"
        self.assertTrue((current / "06_最终成片/output/master-v4.mp4").is_file())
        self.assertTrue((current / "03_图片与封面/platform-packages-v4/douyin/cover.png").is_file())
        self.assertTrue((current / "02_文案与分镜/input/script.txt").is_file())
        self.assertEqual("final_delivery", result["review_mode"])
        verification = MOD.verify(SimpleNamespace(project_root=str(project)))
        self.assertTrue(verification["ok"], verification)
        self.assertTrue(verification["delivery_gate"]["passed"])
        self.assertTrue(verification["review_gate"]["passed"])

    def test_stale_latest_final_delivery_blocks_apply_and_verify(self):
        self.make_final_delivery(stale=True)
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="失效项目", library_root=str(self.library), apply=False)
        preview = MOD.register(args)
        self.assertFalse(preview["classification_gate"]["passed"])
        self.assertFalse(preview["delivery_gate"]["passed"])
        args.apply = True
        with self.assertRaises(MOD.GateError):
            MOD.register(args)

    def test_final_delivery_requires_nonnegative_integer_size(self):
        delivery_path = self.make_final_delivery()
        delivery = json.loads(delivery_path.read_text(encoding="utf-8"))
        delivery["bindings"]["script"].pop("size")
        delivery_path.write_text(json.dumps(delivery, ensure_ascii=False), encoding="utf-8")
        result = MOD.validate_latest_delivery(self.source)
        self.assertFalse(result["passed"])
        self.assertTrue(any("size" in error for error in result["errors"]))

    def test_missing_suspected_json_dependency_blocks_delivery(self):
        delivery_path = self.make_final_delivery()
        episode_path = self.source / "episode-manifest-v4.json"
        episode_path.write_text(json.dumps({"cover": "missing/cover.png"}), encoding="utf-8")
        delivery = json.loads(delivery_path.read_text(encoding="utf-8"))
        delivery["episode_manifest"]["sha256"] = MOD.digest(episode_path)
        delivery["episode_manifest"]["size"] = episode_path.stat().st_size
        delivery_path.write_text(json.dumps(delivery, ensure_ascii=False), encoding="utf-8")
        _, gate = MOD.build_review_selection(self.source, [])
        self.assertFalse(gate["passed"])
        self.assertTrue(any("依赖缺失" in error for error in gate["errors"]))

    def test_mime_and_aspect_ratio_strings_are_not_treated_as_paths(self):
        delivery_path = self.make_final_delivery()
        episode_path = self.source / "episode-manifest-v4.json"
        episode_path.write_text(json.dumps({"mime": "video/mp4", "aspect_ratio": "9/16"}), encoding="utf-8")
        delivery = json.loads(delivery_path.read_text(encoding="utf-8"))
        delivery["episode_manifest"]["sha256"] = MOD.digest(episode_path)
        delivery["episode_manifest"]["size"] = episode_path.stat().st_size
        delivery_path.write_text(json.dumps(delivery, ensure_ascii=False), encoding="utf-8")
        _, gate = MOD.build_review_selection(self.source, [])
        self.assertTrue(gate["passed"], gate)

    def test_oversized_json_is_rejected(self):
        path = self.write("oversized.json", b'{"value":"1234567890"}')
        with mock.patch.object(MOD, "MAX_JSON_BYTES", 8):
            with self.assertRaises(MOD.GateError):
                MOD.load_json_object(path, "测试 JSON")

    def test_transaction_failure_restores_all_previous_views(self):
        source_file = self.write("文案/script.txt", b"one")
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="事务项目", library_root=str(self.library), apply=True)
        MOD.register(args)
        project = self.library / "项目/事务项目"
        before = {name: MOD.tree_hashes(project / name) for name in ("01_给Codex审核", "02_工程源文件", "03_机器清单_勿手改")}
        source_file.write_bytes(b"two")
        original_replace = MOD.os.replace

        def fail_on_machine_promotion(source, target):
            source_path = Path(source)
            if ".transaction-staging-" in str(source_path.parent) and source_path.name == "03_机器清单_勿手改":
                raise OSError("injected promotion failure")
            return original_replace(source, target)

        with mock.patch.object(MOD.os, "replace", side_effect=fail_on_machine_promotion):
            with self.assertRaises(OSError):
                MOD.refresh(SimpleNamespace(project_root=str(project), apply=True))
        after = {name: MOD.tree_hashes(project / name) for name in before}
        self.assertEqual(before, after)
        self.assertEqual([], list(project.glob(".transaction-*-*")))

    def test_new_project_failure_leaves_no_partial_project(self):
        project = self.library / "项目/无残留项目"
        original_replace = MOD.os.replace

        def fail_final_rename(source, target):
            if Path(target).resolve(strict=False) == project.resolve(strict=False):
                raise OSError("injected rename failure")
            return original_replace(source, target)

        args = SimpleNamespace(library_root=str(self.library), project_name="无残留项目", apply=True)
        with mock.patch.object(MOD.os, "replace", side_effect=fail_final_rename):
            with self.assertRaises(OSError):
                MOD.new_project(args)
        self.assertFalse(project.exists())
        self.assertEqual([], list((self.library / "项目").glob(".无残留项目.new-project-*")))

    def test_init_library_shortcut_failure_rolls_back_new_directories(self):
        library = self.root / "new-library"
        shortcut = self.root / "Video Library.lnk"
        args = SimpleNamespace(library_root=str(library), desktop_shortcut=str(shortcut), apply=True)
        failure = MOD.subprocess.CalledProcessError(1, ["powershell"])
        with mock.patch.object(MOD.shutil, "which", return_value="powershell"), mock.patch.object(MOD.subprocess, "run", side_effect=failure):
            with self.assertRaises(MOD.subprocess.CalledProcessError):
                MOD.init_library(args)
        self.assertFalse(library.exists())

    def test_relative_init_paths_are_rejected(self):
        args = SimpleNamespace(library_root="relative-library", desktop_shortcut="relative.lnk", apply=False)
        with self.assertRaises(MOD.GateError):
            MOD.init_library(args)

    def test_verify_detects_missing_current_review_copy(self):
        self.make_final_delivery()
        args = SimpleNamespace(source=str(self.source), review_source=[], project_name="缺文件项目", library_root=str(self.library), apply=True)
        MOD.register(args)
        project = self.library / "项目/缺文件项目"
        target = project / "01_给Codex审核/当前正式版/06_最终成片/output/master-v4.mp4"
        target.unlink()
        verification = MOD.verify(SimpleNamespace(project_root=str(project)))
        self.assertFalse(verification["ok"])
        self.assertTrue(verification["review_gate"]["missing"])


if __name__ == "__main__":
    unittest.main()
