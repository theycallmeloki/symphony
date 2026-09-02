defmodule SymphonyElixir.RepoDeltaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RepoDelta

  describe "repo_name/1" do
    test "derives the mapped repository name from a clone URL" do
      assert RepoDelta.repo_name("https://github.com/theycallmeloki/sandman.git") == "sandman"

      assert RepoDelta.repo_name("https://github.com/theycallmeloki/github-automation") ==
               "github-automation"

      assert RepoDelta.repo_name("https://gitlab.winehq.org/wine/wine.git") == "wine"
    end
  end

  describe "parse_statuses/2" do
    test "splits changed and deleted paths out of git name-status output" do
      dir = tmp_workspace()
      File.write!(Path.join(dir, "a.txt"), "two\n")
      File.write!(Path.join(dir, "keep.txt"), "kept\n")
      File.write!(Path.join(dir, "new.txt"), "fresh\n")

      statuses = "M\0a.txt\0D\0gone.txt\0A\0new.txt\0"
      {files, removed} = RepoDelta.parse_statuses(statuses, dir)

      assert files == %{"a.txt" => "two\n", "new.txt" => "fresh\n"}
      assert removed == %{"gone.txt" => true}
    end

    test "a changed path that vanished from the workspace counts as deleted" do
      dir = tmp_workspace()
      statuses = "M\0vanished.txt\0"
      {files, removed} = RepoDelta.parse_statuses(statuses, dir)
      assert files == %{}
      assert removed == %{"vanished.txt" => true}
    end

    test "empty output yields no edits" do
      dir = tmp_workspace()
      {files, removed} = RepoDelta.parse_statuses("", dir)
      assert files == %{}
      assert removed == %{}
    end
  end

  describe "write_tree/2" do
    test "writes nested paths, creating directories" do
      dir = tmp_workspace()

      assert :ok =
               RepoDelta.write_tree(dir, %{
                 "README.md" => "hello\n",
                 "lib/deep/nested.ex" => "nested\n"
               })

      assert File.read!(Path.join(dir, "README.md")) == "hello\n"
      assert File.read!(Path.join(dir, "lib/deep/nested.ex")) == "nested\n"
    end
  end

  describe "marker round-trip" do
    test "write_marker output is read back by read_marker" do
      dir = tmp_workspace()

      # write_marker is private; exercise the same shape read_marker expects
      marker = Path.join(dir, ".sandman-src")

      File.write!(
        marker,
        Jason.encode!(%{"url" => "https://github.com/theycallmeloki/sandman.git", "branch" => "master", "revision" => "abc123"})
      )

      assert {:ok, %{"url" => url, "branch" => "master", "revision" => "abc123"}} =
               RepoDelta.read_marker(dir)

      assert url == "https://github.com/theycallmeloki/sandman.git"
    end

    test "missing marker reports :not_bootstrapped" do
      assert {:error, :not_bootstrapped} = RepoDelta.read_marker(tmp_workspace())
    end

    test "malformed marker reports :marker_malformed" do
      dir = tmp_workspace()
      File.write!(Path.join(dir, ".sandman-src"), Jason.encode!(%{"url" => 42}))
      assert {:error, _} = RepoDelta.read_marker(dir)
    end
  end

  describe "commit_after_emit/2" do
    test "folds delivered edits into a new base commit and re-points the marker" do
      dir = tmp_workspace()
      git(dir, ["init", "-q"])
      git(dir, ["config", "user.name", "Test"])
      git(dir, ["config", "user.email", "test@example.com"])

      marker = Path.join(dir, ".sandman-src")
      File.write!(marker, Jason.encode!(%{"url" => "https://github.com/theycallmeloki/sandman.git", "branch" => "master", "revision" => "base1"}))

      File.write!(Path.join(dir, ".gitignore"), ".sandman-src\n")
      File.write!(Path.join(dir, "a.txt"), "one\n")
      git(dir, ["add", "-A"])
      git(dir, ["commit", "-q", "-m", "base"])

      # the agent then edits and we deliver those edits at revision "head1"
      File.write!(Path.join(dir, "a.txt"), "two\n")
      File.write!(Path.join(dir, "b.txt"), "new\n")

      assert :ok = RepoDelta.commit_after_emit(dir, "head1")

      # working tree clean: later diffs only see post-delivery edits
      assert git(dir, ["status", "--porcelain"]) == ""

      # marker re-pointed at the delivered revision: the next emit carries a valid base
      assert {:ok, %{"revision" => "head1"}} = RepoDelta.read_marker(dir)

      # a new edit after the fold is visible as a worktree delta vs the new base
      File.write!(Path.join(dir, "b.txt"), "new2\n")
      {files, removed} = RepoDelta.worktree_delta(dir)
      assert Map.keys(files) == ["b.txt"]
      assert removed == []
    end

    test "missing marker makes commit_after_emit a silent no-op" do
      dir = tmp_workspace()
      assert :ok = RepoDelta.commit_after_emit(dir, "head1")
    end
  end

  defp tmp_workspace do
    dir = Path.join(System.tmp_dir!(), "repo_delta_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    output |> String.trim() |> then(& &1)
  end
end
