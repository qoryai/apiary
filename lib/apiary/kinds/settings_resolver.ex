defmodule Apiary.Kinds.SettingsResolver do
  @moduledoc """
  SettingsResolver is the first resolver an integration's settings schema is built with.

  JSV ends every resolver chain with `JSV.Resolver.Internal`, which answers a
  `jsv:module:` reference by loading the module it names, and a resolver's error passes
  the reference on to the next one. A settings schema comes from a description, so every
  `jsv:` reference is answered here with a schema no value is valid against, and the chain
  stops before Internal. Any other reference goes on to JSV's resolvers, as before.
  """

  @behaviour JSV.Resolver

  @impl JSV.Resolver
  def resolve(url, _opts) do
    if url |> String.slice(0, 4) |> String.downcase() == "jsv:",
      do: {:ok, %{"not" => %{}}},
      else: {:error, {:not_jsv, url}}
  end
end
