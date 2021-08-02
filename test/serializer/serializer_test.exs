defmodule Membrane.WAV.SerializerTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Testing.Pipeline

  @module Membrane.WAV.Serializer

  @input_path Path.expand("../fixtures/input.wav", __DIR__)
  @reference_path Path.expand("../fixtures/reference.wav", __DIR__)

  describe "Serializer should" do
    test "create header properly for one channel" do
      caps = %Caps{
        channels: 1,
        sample_rate: 16_000,
        format: :s16le
      }

      reference_header = <<
        "RIFF",
        0::32,
        "WAVE",
        "fmt ",
        16::32-little,
        1::16-little,
        1::16-little,
        16_000::32-little,
        32_000::32-little,
        2::16-little,
        16::16-little,
        "data",
        0::32-little
      >>

      {actions, _state} = @module.handle_caps(:input, caps, %{}, %{})

      assert {:ok,
              caps: _caps,
              buffer: {:output, %Buffer{payload: ^reference_header}},
              redemand: :output} = actions
    end

    test "create header properly for two channels" do
      caps = %Caps{
        channels: 2,
        sample_rate: 44_100,
        format: :s24le
      }

      reference_header = <<
        "RIFF",
        0::32,
        "WAVE",
        "fmt ",
        16::32-little,
        1::16-little,
        2::16-little,
        44_100::32-little,
        264_600::32-little,
        6::16-little,
        24::16-little,
        "data",
        0::32-little
      >>

      {actions, _state} = @module.handle_caps(:input, caps, %{}, %{})

      assert {:ok,
              caps: _caps,
              buffer: {:output, %Buffer{payload: ^reference_header}},
              redemand: :output} = actions
    end

    test "work with Parser" do
      elements = [
        file_src: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        serializer: Membrane.WAV.Serializer,
        sink: Membrane.Testing.Sink
      ]

      links = [
        link(:file_src)
        |> to(:parser)
        |> to(:serializer)
        |> to(:sink)
      ]

      pipeline_options = %Pipeline.Options{elements: elements, links: links}
      assert {:ok, pid} = Pipeline.start_link(pipeline_options)

      {:ok, <<header::44-bytes, payload::8-bytes>>} = File.read(@reference_path)

      assert Pipeline.play(pid) == :ok
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^header})
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload})
      Pipeline.stop_and_terminate(pid, blocking?: true)
    end
  end
end
