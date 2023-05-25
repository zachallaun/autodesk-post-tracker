Mix.install([
  :req
])

defmodule PostChange do
  defstruct [
    :name,
    :date,
    :revision,
    :minimum_revision,
    :messages,
    # :unknown | :committed | :missing
    status: :unknown
  ]

  def from_json!(name, data) do
    %{
      "date" => date_string,
      "revision" => revision,
      "minimumRevision" => min_revision,
      "messages" => messages
    } = data

    %PostChange{
      name: name,
      date: date_string,
      revision: revision,
      minimum_revision: min_revision,
      messages: Enum.map(messages, & &1["message"])
    }
  end

  def filename(%PostChange{name: name}), do: name <> ".cps"

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
  @download_url "https://cam.autodesk.com/posts/download.php?name=mazak&type=post&revision=44066"

  def changes(name \\ "mazak") do
    req()
    |> Req.update(url: @post_changes_url, params: %{name: name})
    |> Req.get!()
    |> Map.fetch!(:body)
    |> Enum.map(&PostChange.from_json!(name, &1))
  end

  def post_processor(%PostChange{name: name, revision: revision}) do
    req()
    |> Req.update(url: @download_url, params: %{type: "post", name: name, revision: revision})
    |> Req.get!()
    |> Map.fetch!(:body)
  end

  defp req do
    Req.new(json: true)
  end
end

defmodule GitOps do
  def initial_commit do
    git(["rev-list", "--max-parents=0", "main"])
  end

  def checkout_and_maybe_init(name) do
    with {:ok, init} <- initial_commit(),
         {:ok, _} <- git(["checkout", "-b", name, init]) do
      {:ok, ""}
    else
      # branch already exists
      {:error, 128, _} -> checkout(name)
    end
  end

  def commit_file(pathspec, message_file, date) do
    with {:ok, _} <- git(["add", pathspec]) do
      git(["commit", "--file", message_file, "--date", date])
    end
  end

  def last_message do
    git(["log", "--pretty=format:%s", "-n1"])
  end

  def checkout(name) do
    git(["checkout", name])
  end

  def stash do
    git(["stash"])
  end

  def stash_pop do
    git(["stash", "pop"])
  end

  def git(command) do
    case System.cmd("git", command) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, code} -> {:error, code, err}
    end
  end
end

defmodule Tracker do
  def get_tracked do
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

  def add_missing_commits!(name) do
    message_file = ".commit_message"

    {:ok, _} = GitOps.stash()
    {:ok, _} = GitOps.checkout_and_maybe_init(name)

    changes =
      name
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

    for change <- changes do
      contents = Download.post_processor(change)
      filename = PostChange.filename(change)
      commit_message = PostChange.commit_message(change)

      File.write!(filename, contents)
      File.write!(message_file, commit_message)

      {:ok, _} = GitOps.commit_file(filename, message_file, change.date)

      File.rm!(message_file)
    end

    {:ok, _} = GitOps.checkout("main")
    GitOps.stash_pop()
  end

  def log(message) do
    prefix = IO.ANSI.format([:cyan, :inverse, " TRACKER "])

    IO.puts(["\n", prefix, " ", message])
  end
end

tracked_posts = Tracker.get_tracked()

Tracker.log("Tracked posts: #{tracked_posts}")

for post <- tracked_posts do
  Tracker.log("Starting: #{post}")
  Tracker.add_missing_commits!(post)
end

Tracker.log("Done!")
