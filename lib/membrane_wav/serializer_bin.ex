defmodule Membrane.WAV.SerializerBin do
  @moduledoc """
  Bin responsible for serializing and saving raw audio to a file in WAV format.

  For more information about WAV serialization, refer to `Membrane.WAV.Serializer`.
  """

  use Membrane.Bin

  alias __MODULE__.Interceptor
  alias Membrane.Caps.Audio.Raw, as: Caps

  alias Membrane.WAV.Serializer
  alias Membrane.File.Sink

  def_input_pad :input, demand_unit: :buffers, caps: Caps

  def_options location: [
                spec: Path.t(),
                description: """
                Output path for the serialized WAV file.
                """
              ],
              serializer_options: [
                spec: Enum.t(),
                description: """
                Options to be passed to serializer. For a list of available options
                refer to `Membrane.WAV.Serializer`.
                """,
                default: %{}
              ]

  @impl true
  def handle_init(options) do
    children = [
      serializer: struct!(Serializer, options.serializer_options),
      interceptor: Interceptor,
      file_sink: %Sink{location: options.location}
    ]

    links = [link_bin_input() |> to(:serializer) |> to(:interceptor) |> to(:file_sink)]

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, nil}
  end

  @impl true
  def handle_element_end_of_stream({:file_sink, _}, _ctx, state) do
    {{:ok, notify: :end_of_stream}, state}
  end

  def handle_element_end_of_stream(_element, _ctx, state) do
    {:ok, state}
  end
end
