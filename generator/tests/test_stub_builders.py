import json

from builders import demographics, turnout


def test_turnout_build_writes_empty_list(tmp_path):
    turnout.build(output_dir=tmp_path)

    assert json.loads((tmp_path / "turnout.json").read_text()) == []


def test_demographics_build_writes_empty_list(tmp_path):
    demographics.build(output_dir=tmp_path)

    assert json.loads((tmp_path / "demographics.json").read_text()) == []
