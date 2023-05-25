Mix.install([
  :req
])

defmodule PostChange do
  defstruct [
    :postid,
    :date,
    :revision,
    :minimum_revision,
    :messages
  ]

  def from_json!(postid, data) do
    %{
      "date" => date_string,
      "revision" => revision,
      "minimumRevision" => min_revision,
      "messages" => messages
    } = data

    %PostChange{
      postid: postid,
      date: date_string,
      revision: revision,
      minimum_revision: min_revision,
      messages: Enum.map(messages, & &1["message"])
    }
  end

  def filename(%PostChange{postid: postid}), do: postid <> ".cps"

  def commit_message(%PostChange{revision: revision, messages: [message]}) do
    """
    [#{revision}] #{message}
    """
  end

  def commit_message(%PostChange{revision: revision, messages: messages}) do
    bulleted = for msg <- messages, do: "* #{msg}"

    """
    [#{revision}] #{length(messages)} messages...

    #{Enum.join(bulleted, "\n")}
    """
  end

  def revision_from_commit_message(message) do
    with "[" <> rest <- message,
         [rev_string, _] <- String.split(rest, "]", parts: 2),
         {revision, ""} <- Integer.parse(rev_string) do
      {:ok, revision}
    else
      _ -> :error
    end
  end
end

defmodule Download do
  @post_changes_url "https://cam.autodesk.com/posts/changes.php"
  @download_url "https://cam.autodesk.com/posts/download.php"

  def changes(postid) do
    req()
    |> Req.update(url: @post_changes_url, params: %{name: name(postid)})
    |> Req.get!()
    |> Map.fetch!(:body)
    |> Enum.map(&PostChange.from_json!(postid, &1))
  end

  def post_processor(%PostChange{postid: postid, revision: revision}) do
    req()
    |> Req.update(
      url: @download_url,
      params: %{type: "post", name: name(postid), revision: revision}
    )
    |> Req.get!()
    |> Map.fetch!(:body)
  end

  defp req do
    Req.new(json: true)
  end

  defp name(postid) do
    String.replace(postid, "_", " ")
  end
end

defmodule GitOps do
  def initial_commit do
    git(["rev-list", "--max-parents=0", "main"])
  end

  def checkout_and_maybe_init(branch) do
    with {:ok, init} <- initial_commit(),
         {:ok, _} <- git(["checkout", "-b", branch, init]) do
      {:ok, ""}
    else
      # branch already exists
      {:error, 128, _} -> checkout(branch)
    end
  end

  def commit_file(pathspec, message_file, date) do
    env = [
      {"GIT_AUTHOR_DATE", date},
      {"GIT_COMMITTER_DATE", date}
    ]

    with {:ok, _} <- git(["add", pathspec]) do
      git(["commit", "--file", message_file], env: env)
    end
  end

  def checkout(branch), do: git(["checkout", branch])

  def stash, do: git(["stash"])

  def stash_pop, do: git(["stash", "pop"])

  def last_message, do: git(["log", "--pretty=format:%s", "-n1"])

  def diff, do: git(["diff"])

  def git(command, cmd_opts \\ []) do
    case System.cmd("git", command, cmd_opts) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, code} -> {:error, code, err}
    end
  end
end

defmodule Tracker do
  @message_file ".commit_message"

  def add_all_missing_commits! do
    tracked_posts =
      case System.argv() do
        [] -> tracked_posts()
        postids -> postids
      end

    log("Tracking: #{Enum.join(tracked_posts, ", ")}")

    did_stash? =
      case GitOps.diff() do
        {:ok, ""} ->
          false

        {:ok, _} ->
          Tracker.log("Stashing changes")
          {:ok, _} = GitOps.stash()
          true
      end

    for post <- tracked_posts do
      Tracker.log("Starting: #{post}")
      Tracker.add_missing_commits!(post)
    end

    if did_stash? do
      Tracker.log("Unstashing changes")
      GitOps.stash_pop()
    end

    Tracker.log("Done!")
  end

  def add_missing_commits!(postid) do
    {:ok, _} = GitOps.checkout_and_maybe_init(postid)

    changes =
      postid
      |> Download.changes()
      |> Enum.reverse()

    {:ok, last_message} = GitOps.last_message()

    changes =
      case PostChange.revision_from_commit_message(last_message) do
        {:ok, last_known_revision} ->
          Enum.drop_while(changes, &(&1.revision <= last_known_revision))

        :error ->
          changes
      end

    changes
    |> Task.async_stream(fn change -> {change, Download.post_processor(change)} end)
    |> Enum.each(fn {:ok, {change, contents}} ->
      filename = PostChange.filename(change)
      commit_message = PostChange.commit_message(change)

      File.write!(filename, contents)
      File.write!(@message_file, commit_message)

      {:ok, _} = GitOps.commit_file(filename, @message_file, change.date)

      File.rm!(@message_file)
    end)

    {:ok, _} = GitOps.checkout("main")
  end

  def tracked_posts do
    "README.md"
    |> File.read!()
    |> String.split("<!-- TRACKED -->")
    |> Enum.at(1)
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn s ->
      [_, url_and_rest] = String.split(s, "(", parts: 2)
      [url, _] = String.split(url_and_rest, ")", parts: 2)

      url
      |> Path.basename()
      |> Path.rootname()
    end)
  end

  def log(message) do
    prefix = IO.ANSI.format([:cyan, :inverse, " TRACKER "])

    IO.puts(["\n", prefix, " ", message])
  end
end

Tracker.add_all_missing_commits!()
