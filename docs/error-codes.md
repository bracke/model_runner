# Error-code reference

Generated from `Model_Runner.Errors.Error_Code` by `tests docs`.
Do not edit by hand.

A code is stable: the ordinal is the literal's position within its
domain group, so codes are appended, never reordered or removed.

A code marked reserved is declared and carries a message, and
nothing in the program raises it. Some are superseded by a more
precise diagnostic -- a closed session names the state it is in
rather than reporting that it is closed -- and some describe a
condition that cannot arise. They are listed because a published
ordinal is never reused, not because they might appear.


## CLI

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-CLI-0001` | `error.cli.missing_command` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0002` | `error.cli.unknown_command` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0003` | `error.cli.unknown_option` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0004` | `error.cli.missing_option_value` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0005` | `error.cli.unexpected_option_value` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0006` | `error.cli.invalid_option_value` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0007` | `error.cli.option_out_of_range` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0008` | `error.cli.repeated_option` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0009` | `error.cli.conflicting_prompt_sources` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0010` | `error.cli.conflicting_system_sources` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0011` | `error.cli.raw_mode_conflict` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0012` | `error.cli.missing_model_path` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0013` | `error.cli.unexpected_operand` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0014` | `error.cli.invalid_locale` | recovery_user_correctable | 2 | reserved |
| `MR-CLI-0015` | `error.cli.invalid_color_mode` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0016` | `error.cli.invalid_mapping_mode` | recovery_user_correctable | 2 | reserved |
| `MR-CLI-0017` | `error.cli.no_prompt_available` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0018` | `error.cli.interactive_unavailable` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0019` | `error.cli.invalid_environment_value` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0020` | `error.cli.option_not_for_command` | recovery_user_correctable | 2 | raised |
| `MR-CLI-0021` | `error.cli.option_combination` | recovery_user_correctable | 2 | raised |

## IO

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-IO-0001` | `error.io.open_failed` | recovery_user_correctable | 6 | raised |
| `MR-IO-0002` | `error.io.read_failed` | recovery_user_correctable | 6 | raised |
| `MR-IO-0003` | `error.io.write_failed` | recovery_user_correctable | 6 | reserved |
| `MR-IO-0004` | `error.io.file_too_large` | recovery_resource_limited | 6 | raised |
| `MR-IO-0005` | `error.io.not_a_regular_file` | recovery_user_correctable | 6 | raised |
| `MR-IO-0006` | `error.io.invalid_utf8` | recovery_user_correctable | 6 | raised |
| `MR-IO-0007` | `error.io.output_closed` | recovery_user_correctable | 6 | reserved |
| `MR-IO-0008` | `error.io.seek_failed` | recovery_user_correctable | 6 | reserved |
| `MR-IO-0009` | `error.io.input_too_large` | recovery_user_correctable | 6 | raised |

## GGUF

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-GGUF-0001` | `error.gguf.truncated` | recovery_none | 3 | raised |
| `MR-GGUF-0002` | `error.gguf.invalid_magic` | recovery_none | 3 | raised |
| `MR-GGUF-0003` | `error.gguf.unsupported_version` | recovery_unsupported | 4 | raised |
| `MR-GGUF-0004` | `error.gguf.metadata_count_too_large` | recovery_none | 3 | raised |
| `MR-GGUF-0005` | `error.gguf.tensor_count_too_large` | recovery_none | 3 | raised |
| `MR-GGUF-0006` | `error.gguf.invalid_string_length` | recovery_none | 3 | raised |
| `MR-GGUF-0007` | `error.gguf.invalid_utf8` | recovery_none | 3 | raised |
| `MR-GGUF-0008` | `error.gguf.unknown_value_type` | recovery_none | 3 | raised |
| `MR-GGUF-0009` | `error.gguf.invalid_array_element_type` | recovery_none | 3 | raised |
| `MR-GGUF-0010` | `error.gguf.array_too_large` | recovery_none | 3 | raised |
| `MR-GGUF-0011` | `error.gguf.empty_metadata_key` | recovery_none | 3 | raised |
| `MR-GGUF-0012` | `error.gguf.duplicate_metadata_key` | recovery_none | 3 | raised |
| `MR-GGUF-0013` | `error.gguf.empty_tensor_name` | recovery_none | 3 | raised |
| `MR-GGUF-0014` | `error.gguf.duplicate_tensor_name` | recovery_none | 3 | raised |
| `MR-GGUF-0015` | `error.gguf.invalid_tensor_rank` | recovery_none | 3 | raised |
| `MR-GGUF-0016` | `error.gguf.invalid_tensor_dimension` | recovery_none | 3 | raised |
| `MR-GGUF-0017` | `error.gguf.unknown_tensor_type` | recovery_none | 3 | raised |
| `MR-GGUF-0018` | `error.gguf.unsupported_tensor_type` | recovery_unsupported | 4 | reserved |
| `MR-GGUF-0019` | `error.gguf.block_misalignment` | recovery_none | 3 | raised |
| `MR-GGUF-0020` | `error.gguf.invalid_alignment` | recovery_none | 3 | raised |
| `MR-GGUF-0021` | `error.gguf.tensor_offset_misaligned` | recovery_none | 3 | raised |
| `MR-GGUF-0022` | `error.gguf.tensor_out_of_bounds` | recovery_none | 3 | raised |
| `MR-GGUF-0023` | `error.gguf.tensor_overlap` | recovery_none | 3 | raised |
| `MR-GGUF-0024` | `error.gguf.arithmetic_overflow` | recovery_none | 3 | raised |
| `MR-GGUF-0025` | `error.gguf.trailing_data` | recovery_none | 3 | raised |
| `MR-GGUF-0026` | `error.gguf.missing_metadata_key` | recovery_none | 3 | raised |
| `MR-GGUF-0027` | `error.gguf.metadata_type_mismatch` | recovery_none | 3 | raised |
| `MR-GGUF-0028` | `error.gguf.metadata_out_of_range` | recovery_none | 3 | raised |
| `MR-GGUF-0029` | `error.gguf.file_changed` | recovery_none | 3 | raised |

## TOK

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-TOK-0001` | `error.tokenizer.missing_model` | recovery_none | 3 | raised |
| `MR-TOK-0002` | `error.tokenizer.unsupported_model` | recovery_unsupported | 4 | raised |
| `MR-TOK-0003` | `error.tokenizer.missing_tokens` | recovery_none | 3 | raised |
| `MR-TOK-0004` | `error.tokenizer.invalid_vocabulary` | recovery_none | 3 | raised |
| `MR-TOK-0005` | `error.tokenizer.vocabulary_too_large` | recovery_none | 3 | raised |
| `MR-TOK-0006` | `error.tokenizer.invalid_token_text` | recovery_none | 3 | raised |
| `MR-TOK-0007` | `error.tokenizer.invalid_token_id` | recovery_none | 3 | raised |
| `MR-TOK-0008` | `error.tokenizer.invalid_merges` | recovery_none | 3 | raised |
| `MR-TOK-0009` | `error.tokenizer.invalid_scores` | recovery_none | 3 | raised |
| `MR-TOK-0010` | `error.tokenizer.invalid_token_type` | recovery_none | 3 | raised |
| `MR-TOK-0011` | `error.tokenizer.input_too_long` | recovery_resource_limited | 3 | raised |
| `MR-TOK-0012` | `error.tokenizer.invalid_utf8` | recovery_none | 3 | raised |
| `MR-TOK-0013` | `error.tokenizer.buffer_too_small` | recovery_none | 3 | raised |
| `MR-TOK-0014` | `error.tokenizer.missing_byte_fallback` | recovery_unsupported | 4 | raised |

## TMPL

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-TMPL-0001` | `error.template.missing` | recovery_none | 3 | raised |
| `MR-TMPL-0002` | `error.template.unsupported_construct` | recovery_unsupported | 4 | raised |
| `MR-TMPL-0003` | `error.template.syntax_error` | recovery_none | 3 | raised |
| `MR-TMPL-0004` | `error.template.too_large` | recovery_none | 3 | raised |
| `MR-TMPL-0005` | `error.template.nesting_too_deep` | recovery_none | 3 | raised |
| `MR-TMPL-0006` | `error.template.unknown_variable` | recovery_none | 3 | raised |
| `MR-TMPL-0007` | `error.template.unknown_filter` | recovery_none | 3 | raised |
| `MR-TMPL-0008` | `error.template.output_too_large` | recovery_resource_limited | 3 | raised |
| `MR-TMPL-0009` | `error.template.iteration_limit` | recovery_none | 3 | raised |
| `MR-TMPL-0010` | `error.template.unbalanced_block` | recovery_none | 3 | raised |
| `MR-TMPL-0011` | `error.template.unsupported_role` | recovery_unsupported | 4 | reserved |
| `MR-TMPL-0012` | `error.template.variables_too_large` | recovery_resource_limited | 3 | raised |
| `MR-TMPL-0013` | `error.template.unknown_format` | recovery_none | 2 | raised |

## GRAM

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-GRAM-0001` | `error.grammar.syntax_error` | recovery_none | 2 | raised |
| `MR-GRAM-0002` | `error.grammar.unknown_rule` | recovery_none | 2 | raised |
| `MR-GRAM-0003` | `error.grammar.missing_root` | recovery_none | 2 | raised |
| `MR-GRAM-0004` | `error.grammar.too_large` | recovery_none | 2 | raised |
| `MR-GRAM-0005` | `error.grammar.nesting_too_deep` | recovery_none | 2 | raised |
| `MR-GRAM-0006` | `error.grammar.too_ambiguous` | recovery_none | 2 | raised |
| `MR-GRAM-0007` | `error.grammar.rejected_every_token` | recovery_none | 2 | raised |
| `MR-GRAM-0008` | `error.grammar.schema_unsupported` | recovery_none | 2 | raised |

## TOOLS

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-TOOLS-0001` | `error.tools.invalid_json` | recovery_none | 2 | raised |
| `MR-TOOLS-0002` | `error.tools.not_an_object` | recovery_none | 2 | raised |
| `MR-TOOLS-0003` | `error.tools.missing_name` | recovery_none | 2 | raised |
| `MR-TOOLS-0004` | `error.tools.too_many` | recovery_resource_limited | 2 | raised |
| `MR-TOOLS-0005` | `error.tools.too_large` | recovery_resource_limited | 2 | raised |
| `MR-TOOLS-0006` | `error.tools.nesting_too_deep` | recovery_none | 2 | raised |
| `MR-TOOLS-0007` | `error.tools.call_malformed` | recovery_none | 3 | raised |
| `MR-TOOLS-0008` | `error.tools.not_in_template` | recovery_unsupported | 4 | raised |

## ARCH

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-ARCH-0001` | `error.architecture.missing_identifier` | recovery_none | 3 | raised |
| `MR-ARCH-0002` | `error.architecture.unsupported` | recovery_unsupported | 4 | raised |
| `MR-ARCH-0003` | `error.architecture.missing_metadata` | recovery_none | 3 | reserved |
| `MR-ARCH-0004` | `error.architecture.invalid_metadata` | recovery_none | 3 | reserved |
| `MR-ARCH-0005` | `error.architecture.invalid_dimensions` | recovery_none | 3 | raised |
| `MR-ARCH-0006` | `error.architecture.invalid_head_counts` | recovery_none | 3 | raised |
| `MR-ARCH-0007` | `error.architecture.invalid_rope` | recovery_none | 3 | raised |
| `MR-ARCH-0008` | `error.architecture.unsupported_rope_scaling` | recovery_unsupported | 4 | raised |
| `MR-ARCH-0009` | `error.architecture.unsupported_feature` | recovery_unsupported | 4 | raised |
| `MR-ARCH-0010` | `error.architecture.missing_tensor` | recovery_none | 3 | raised |
| `MR-ARCH-0011` | `error.architecture.invalid_tensor_shape` | recovery_none | 3 | raised |
| `MR-ARCH-0012` | `error.architecture.invalid_tensor_format` | recovery_none | 3 | raised |
| `MR-ARCH-0013` | `error.architecture.vocabulary_mismatch` | recovery_none | 3 | reserved |
| `MR-ARCH-0014` | `error.architecture.context_too_large` | recovery_none | 3 | raised |
| `MR-ARCH-0015` | `error.architecture.layer_numbering_gap` | recovery_none | 3 | reserved |
| `MR-ARCH-0016` | `error.architecture.no_output_head` | recovery_unsupported | 4 | raised |
| `MR-ARCH-0017` | `error.architecture.text_not_whole` | recovery_unsupported | 4 | raised |

## TENSOR

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-TENSOR-0001` | `error.tensor.invalid_shape` | recovery_none | 3 | raised |
| `MR-TENSOR-0002` | `error.tensor.rank_too_high` | recovery_none | 3 | reserved |
| `MR-TENSOR-0003` | `error.tensor.invalid_stride` | recovery_none | 3 | reserved |
| `MR-TENSOR-0004` | `error.tensor.out_of_bounds` | recovery_none | 3 | raised |
| `MR-TENSOR-0005` | `error.tensor.format_unsupported` | recovery_unsupported | 4 | raised |
| `MR-TENSOR-0006` | `error.tensor.block_misaligned` | recovery_none | 3 | raised |
| `MR-TENSOR-0007` | `error.tensor.read_only` | recovery_none | 3 | reserved |
| `MR-TENSOR-0008` | `error.tensor.shape_mismatch` | recovery_none | 3 | raised |
| `MR-TENSOR-0009` | `error.tensor.non_finite_value` | recovery_none | 3 | raised |

## BACKEND

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-BACKEND-0001` | `error.backend.unknown` | recovery_none | 2 | raised |
| `MR-BACKEND-0002` | `error.backend.unsupported_format` | recovery_unsupported | 4 | raised |
| `MR-BACKEND-0003` | `error.backend.capability_missing` | recovery_unsupported | 4 | raised |
| `MR-BACKEND-0004` | `error.backend.worker_failed` | recovery_none | 8 | raised |
| `MR-BACKEND-0005` | `error.backend.queue_full` | recovery_resource_limited | 8 | reserved |
| `MR-BACKEND-0006` | `error.backend.closed` | recovery_none | 8 | raised |
| `MR-BACKEND-0007` | `error.backend.invalid_worker_count` | recovery_none | 8 | reserved |
| `MR-BACKEND-0008` | `error.backend.no_device` | recovery_none | 8 | raised |
| `MR-BACKEND-0009` | `error.backend.device_stalled` | recovery_none | 8 | raised |
| `MR-BACKEND-0010` | `error.backend.device_refused` | recovery_none | 8 | raised |
| `MR-BACKEND-0011` | `error.backend.product_too_large` | recovery_unsupported | 4 | raised |

## MEM

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-MEM-0001` | `error.memory.limit_exceeded` | recovery_resource_limited | 5 | raised |
| `MR-MEM-0002` | `error.memory.allocation_failed` | recovery_resource_limited | 5 | raised |
| `MR-MEM-0003` | `error.memory.plan_overflow` | recovery_resource_limited | 5 | raised |
| `MR-MEM-0004` | `error.memory.invalid_limit` | recovery_none | 5 | reserved |

## LIFE

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-LIFE-0001` | `error.lifecycle.invalid_state` | recovery_terminal | 8 | raised |
| `MR-LIFE-0002` | `error.lifecycle.model_not_ready` | recovery_terminal | 8 | raised |
| `MR-LIFE-0003` | `error.lifecycle.session_active` | recovery_terminal | 8 | raised |
| `MR-LIFE-0004` | `error.lifecycle.session_closed` | recovery_terminal | 8 | reserved |
| `MR-LIFE-0005` | `error.lifecycle.session_failed` | recovery_terminal | 8 | reserved |
| `MR-LIFE-0006` | `error.lifecycle.already_closed` | recovery_terminal | 8 | reserved |
| `MR-LIFE-0007` | `error.lifecycle.mapping_unavailable` | recovery_terminal | 8 | reserved |
| `MR-LIFE-0008` | `error.lifecycle.mapping_required` | recovery_resource_limited | 5 | raised |
| `MR-LIFE-0009` | `error.lifecycle.cache_unreadable` | recovery_terminal | 8 | raised |
| `MR-LIFE-0010` | `error.lifecycle.cache_mismatched` | recovery_terminal | 8 | raised |

## GEN

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-GEN-0001` | `error.generation.prompt_too_long` | recovery_none | 2 | raised |
| `MR-GEN-0002` | `error.generation.context_exhausted` | recovery_resource_limited | 5 | raised |
| `MR-GEN-0003` | `error.generation.invalid_request` | recovery_none | 2 | raised |
| `MR-GEN-0004` | `error.generation.cancelled` | recovery_none | 7 | raised |
| `MR-GEN-0005` | `error.generation.output_closed` | recovery_none | 0 | reserved |
| `MR-GEN-0006` | `error.generation.no_logits` | recovery_none | 8 | reserved |
| `MR-GEN-0007` | `error.generation.batch_too_large` | recovery_none | 2 | reserved |
| `MR-GEN-0008` | `error.generation.empty_prompt` | recovery_none | 2 | raised |

## SAMPLE

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-SAMPLE-0001` | `error.sampling.invalid_configuration` | recovery_none | 2 | raised |
| `MR-SAMPLE-0002` | `error.sampling.vocabulary_mismatch` | recovery_none | 8 | raised |
| `MR-SAMPLE-0003` | `error.sampling.non_finite_logit` | recovery_none | 8 | raised |
| `MR-SAMPLE-0004` | `error.sampling.no_candidates` | recovery_none | 8 | raised |
| `MR-SAMPLE-0005` | `error.sampling.invalid_distribution` | recovery_none | 8 | raised |

## CONV

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-CONV-0001` | `error.conversation.too_long` | recovery_resource_limited | 2 | raised |
| `MR-CONV-0002` | `error.conversation.invalid_role` | recovery_user_correctable | 2 | reserved |
| `MR-CONV-0003` | `error.conversation.empty` | recovery_user_correctable | 2 | raised |
| `MR-CONV-0004` | `error.conversation.system_unsupported` | recovery_unsupported | 4 | reserved |

## INTERNAL

| Code | Message key | Recovery | Exit | State |
| --- | --- | --- | --- | --- |
| `MR-INTERNAL-0001` | `error.internal.invariant_violated` | recovery_terminal | 8 | raised |
| `MR-INTERNAL-0002` | `error.internal.unexpected_exception` | recovery_terminal | 8 | raised |
| `MR-INTERNAL-0003` | `error.internal.not_implemented` | recovery_unsupported | 4 | reserved |
| `MR-INTERNAL-0004` | `error.internal.localization_failed` | recovery_terminal | 8 | reserved |
