#include <Storages/MergeTree/Compaction/MergeSelectors/SimpleMergeSelector.h>
#include <Storages/MergeTree/Compaction/PartProperties.h>
#include <Storages/MergeTree/Compaction/PartitionStatistics.h>
#include <Storages/MergeTree/MergeTreePartInfo.h>

#include <IO/ReadBufferFromFileDescriptor.h>
#include <IO/Operators.h>
#include <Common/formatReadable.h>

#include <cstdlib>
#include <iostream>
#include <Examples/clickhouse_examples.h>

/** One round of merge selection over a partition as a server saw it, with the server's
  * settings, for checking a selector change against a state read from system.part_log:
  *
  *   BASE=10 SMALL_MIN_COUNT=30 RIGHT_TAIL=1 RECHECK=1 clickhouse-examples merge_selector_murasil < parts.tsv
  *
  * where each line is `name\tsize_in_bytes\tage_seconds`. Prints the range the selector
  * picks, or "nothing".
  */

int mainEntryExampleMergeSelectorMurasil(int, char **)
{
    using namespace DB;

    auto env = [](const char * name, double fallback)
    {
        const char * value = std::getenv(name);
        return value ? std::atof(value) : fallback;
    };

    PartsRanges ranges(1);
    PartsRange & parts = ranges.back();
    PartitionsStatistics statistics;

    SimpleMergeSelector::Settings settings;
    settings.base = env("BASE", 5.0);
    settings.small_parts_min_count = static_cast<size_t>(env("SMALL_MIN_COUNT", 0));
    settings.enable_heuristic_to_remove_small_parts_at_right = env("RIGHT_TAIL", 1) != 0;
    settings.recheck_base_after_right_tail_trim = env("RECHECK", 1) != 0;
    settings.partitions_stats = &statistics;
    SimpleMergeSelector selector(settings);

    ReadBufferFromFileDescriptor in(STDIN_FILENO);
    while (!in.eof())
    {
        size_t size = {};
        time_t age = {};
        std::string name;
        in >> name >> "\t" >> size >> "\t" >> age >> "\n";

        auto part_info = MergeTreePartInfo::fromPartName(name, MERGE_TREE_DATA_MIN_FORMAT_VERSION_WITH_CUSTOM_PARTITIONING);
        parts.push_back(PartProperties{.name = name, .info = part_info, .size = size, .age = age, .rows = size / 20});

        PartitionStatistics & partition_stats = statistics[part_info.getPartitionId()];
        partition_stats.min_age = std::min(partition_stats.min_age, age);
        ++partition_stats.part_count;
        partition_stats.total_size += size;
    }

    std::vector<MergeConstraint> constraints{{100ULL * 1024 * 1024 * 1024, std::numeric_limits<size_t>::max()}};
    PartsRanges selected = selector.select(ranges, constraints, nullptr);

    if (selected.empty())
    {
        std::cout << "nothing\n";
        return 0;
    }

    for (const auto & range : selected)
    {
        size_t sum = 0;
        for (const auto & part : range)
            sum += part.size;
        std::cout << range.size() << " parts, " << formatReadableSizeWithBinarySuffix(sum) << ":";
        for (const auto & part : range)
            std::cout << " " << part.name << "(" << formatReadableSizeWithBinarySuffix(part.size) << ")";
        std::cout << "\n";
    }
    return 0;
}
