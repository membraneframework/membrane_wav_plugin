defmodule Membrane.WAV.ParserTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Testing.{Pipeline, Sink}

  @module Membrane.WAV.Parser

  @input_path Path.expand("../fixtures/input.wav", __DIR__)
  @reference_path Path.expand("../fixtures/reference.raw", __DIR__)

  defp prepare_output() do
    output_path = Path.expand("../fixtures/output.raw", __DIR__)

    File.rm(output_path)
    on_exit(fn -> File.rm(output_path) end)

    output_path
  end

  defp perform_test(elements, links) do
    pipeline_options = %Pipeline.Options{elements: elements, links: links}
    assert {:ok, pid} = Pipeline.start_link(pipeline_options)

    assert Pipeline.play(pid) == :ok
    assert_end_of_stream(pid, :file_sink, :input, 5_000)
    Pipeline.stop_and_terminate(pid, blocking?: true)
  end

  describe "Parser should" do
    test "parse and send proper caps" do
      expected_caps = %Caps{
        channels: 1,
        sample_rate: 16_000,
        format: :s16le
      }

      elements = [
        file_src: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        sink: Sink
      ]

      links = [
        link(:file_src)
        |> to(:parser)
        |> to(:sink)
      ]

      pipeline_options = %Pipeline.Options{elements: elements, links: links}
      assert {:ok, pid} = Pipeline.start_link(pipeline_options)

      assert Pipeline.play(pid) == :ok
      assert_sink_caps(pid, :sink, ^expected_caps)
      Pipeline.stop_and_terminate(pid, blocking?: true)
    end

    test "drop header" do
      output_path = prepare_output()

      elements = [
        file_src: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        file_sink: %Membrane.File.Sink{location: output_path}
      ]

      links = [
        link(:file_src)
        |> to(:parser)
        |> to(:file_sink)
      ]

      perform_test(elements, links)

      assert {:ok, reference_file} = File.read(@reference_path)
      assert {:ok, output_file} = File.read(output_path)
      assert output_file == reference_file
    end

    test "raise an error in case of unsupported format or format subchunk length" do
      # contains format equal to 2 (not PCM)
      payload_unsupported_format =
        <<82, 73, 70, 70, 52, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0, 2, 0>>

      # contains format subchunk length equal to 18 (PCM should have 16)
      payload_unsupported_format_length =
        <<82, 73, 70, 70, 52, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 18, 0, 0, 0, 1, 0>>

      assert_raise(
        RuntimeError,
        "formats different than PCM are not supported; expected 1, given 2; format subchunk size: 16",
        fn ->
          @module.handle_process(
            :input,
            %Buffer{payload: payload_unsupported_format},
            nil,
            %{stage: :init, queue: <<>>}
          )
        end
      )

      assert_raise(
        RuntimeError,
        "format subchunk size different than supported; expected 16, given 18",
        fn ->
          @module.handle_process(
            :input,
            %Buffer{payload: payload_unsupported_format_length},
            nil,
            %{stage: :init, queue: <<>>}
          )
        end
      )
    end

    test "work properly with FFmpeg SWResample Converter" do
      output_path = prepare_output()

      elements = [
        file_src: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        converter: %Membrane.FFmpeg.SWResample.Converter{
          input_caps: %Membrane.Caps.Audio.Raw{channels: 1, sample_rate: 16_000, format: :s16le},
          output_caps: %Membrane.Caps.Audio.Raw{channels: 2, sample_rate: 16_000, format: :s16le}
        },
        file_sink: %Membrane.File.Sink{location: output_path}
      ]

      links = [
        link(:file_src)
        |> to(:parser)
        |> to(:converter)
        |> to(:file_sink)
      ]

      perform_test(elements, links)

      assert {:ok, output_file} = File.read(output_path)
      assert byte_size(output_file) == 16
    end
  end
end
