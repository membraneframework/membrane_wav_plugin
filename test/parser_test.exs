defmodule Membrane.WAV.ParserTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ParentSpec

  alias Membrane.{Buffer, RawAudio}
  alias Membrane.Testing.{Pipeline, Sink}

  @module Membrane.WAV.Parser

  @input_path Path.expand("fixtures/input.wav", __DIR__)
  @reference_path Path.expand("fixtures/reference.raw", __DIR__)

  defp perform_test(elements, links) do
    pipeline_options = %Pipeline.Options{elements: elements, links: links}
    assert {:ok, pid} = Pipeline.start_link(pipeline_options)

    assert Pipeline.play(pid) == :ok
    assert_start_of_stream(pid, :file_sink, :input)
    assert_end_of_stream(pid, :file_sink, :input, 5_000)
    Pipeline.stop_and_terminate(pid, blocking?: true)
  end

  test "parse and send proper format" do
    expected_format = %RawAudio{
      channels: 1,
      sample_rate: 16_000,
      sample_format: :s16le
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
    assert_sink_caps(pid, :sink, ^expected_format)
    Pipeline.stop_and_terminate(pid, blocking?: true)
  end

  test "raise an error in case of unsupported format or format chunk length" do
    # contains format equal to 2 (not PCM)
    payload_unsupported_format =
      <<82, 73, 70, 70, 52, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0, 2, 0>>

    # contains format chunk length equal to 18 (PCM should have 16)
    payload_unsupported_format_length =
      <<82, 73, 70, 70, 52, 0, 0, 0, 87, 65, 86, 69, 102, 109, 116, 32, 18, 0, 0, 0, 1, 0>>

    assert_raise(
      RuntimeError,
      ~r"formats different than PCM are not supported",
      fn ->
        @module.handle_process_list(
          :input,
          [%Buffer{payload: payload_unsupported_format}],
          nil,
          %{stage: :init, unparsed_data: <<>>}
        )
      end
    )

    assert_raise(
      RuntimeError,
      ~r"format chunk size different than supported",
      fn ->
        @module.handle_process_list(
          :input,
          [%Buffer{payload: payload_unsupported_format_length}],
          nil,
          %{stage: :init, unparsed_data: <<>>}
        )
      end
    )
  end

  describe "In pipeline Parser should" do
    @describetag :tmp_dir

    test "drop header", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "output.raw")

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

    test "work properly with FFmpeg SWResample Converter", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "output.raw")

      elements = [
        file_src: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        converter: %Membrane.FFmpeg.SWResample.Converter{
          input_caps: %RawAudio{channels: 1, sample_rate: 16_000, sample_format: :s16le},
          output_caps: %RawAudio{channels: 2, sample_rate: 16_000, sample_format: :s16le}
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
