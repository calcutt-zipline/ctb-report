from ctb_report.domain.pathing import normalize_path_without_revision


def test_normalize_path_without_revision_removes_revision_tokens() -> None:
    assert normalize_path_without_revision("ABC:REV1|DEF:REV2") == "ABC|DEF"


def test_normalize_path_without_revision_collapses_duplicate_separators() -> None:
    assert normalize_path_without_revision("|ABC:REV1||DEF:REV2|||") == "ABC|DEF"
