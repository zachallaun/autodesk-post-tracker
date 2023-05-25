Mix.install([
  :req
])

post_changes_url = "https://cam.autodesk.com/posts/changes.php"
download_url = "https://cam.autodesk.com/posts/download.php?name=mazak&type=post&revision=44066"

defmodule PostChange do
  defstruct [
    :name,
    :date,
    :revision,
    :minimum_revision,
    :messages,
    status: :unknown # :unknown | :committed | :missing
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
      messages: Enum.map(messages, &(&1["message"]))
    }
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

  def post(%PostChange{name: name, revision: revision}) do
    req()
    |> Req.update(url: @download_url, params: %{type: "post", name: name, revision: revision})
    |> Req.get!()
    |> Map.fetch!(:headers)
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
      :ok
    else
      # branch already exists
      {:error, 128, _} -> checkout(name)
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

with {:ok, _} <- GitOps.stash(),
     resp <- GitOps.checkout_and_maybe_init("testing"),
     {:ok, _} <- GitOps.checkout("main"),
     {:ok, _} <- GitOps.stash_pop() do
  resp
end
|> IO.inspect()
