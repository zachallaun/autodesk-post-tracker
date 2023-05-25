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

Download.changes() |> List.first() |> Download.post() |> IO.inspect()
