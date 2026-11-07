#include <Columns/ColumnLowCardinality.h>
#include <DataTypes/DataTypeFactory.h>
#include <DataTypes/IDataType.h>
#include <Formats/FormatSettings.h>
#include <IO/ReadBufferFromString.h>

#include <gtest/gtest.h>

using namespace DB;

namespace
{

void readWholeText(const DataTypePtr & type, IColumn & column, const std::string & text)
{
    ReadBufferFromString in(text);
    type->getDefaultSerialization()->deserializeWholeText(column, in, FormatSettings{});
}

bool tryReadWholeText(const DataTypePtr & type, IColumn & column, const std::string & text)
{
    ReadBufferFromString in(text);
    return type->getDefaultSerialization()->tryDeserializeWholeText(column, in, FormatSettings{});
}

}

/// Values of a LowCardinality column read one at a time in a row format go through a scratch
/// column of the nested type that the thread keeps between values and between types. Reading
/// values of two types in turn, and a value that fails to read, must not leak into later values.
TEST(SerializationLowCardinality, RowFormatValuesSurviveTypeChangesAndFailures)
{
    const auto & factory = DataTypeFactory::instance();
    auto strings_type = factory.get("LowCardinality(String)");
    auto numbers_type = factory.get("LowCardinality(UInt32)");
    auto nullable_type = factory.get("LowCardinality(Nullable(String))");

    auto strings = strings_type->createColumn();
    auto numbers = numbers_type->createColumn();
    auto nullables = nullable_type->createColumn();

    readWholeText(strings_type, *strings, "alpha");
    readWholeText(strings_type, *strings, "beta");
    readWholeText(numbers_type, *numbers, "7");
    readWholeText(strings_type, *strings, "alpha");
    readWholeText(numbers_type, *numbers, "8");

    ASSERT_FALSE(tryReadWholeText(numbers_type, *numbers, "not a number"));
    ASSERT_TRUE(tryReadWholeText(numbers_type, *numbers, "9"));
    EXPECT_THROW(readWholeText(numbers_type, *numbers, "still not a number"), Exception);
    readWholeText(numbers_type, *numbers, "10");

    readWholeText(nullable_type, *nullables, "gamma");
    readWholeText(nullable_type, *nullables, "NULL");
    readWholeText(strings_type, *strings, "gamma");

    ASSERT_EQ(strings->size(), 4u);
    EXPECT_EQ((*strings)[0].safeGet<String>(), "alpha");
    EXPECT_EQ((*strings)[1].safeGet<String>(), "beta");
    EXPECT_EQ((*strings)[2].safeGet<String>(), "alpha");
    EXPECT_EQ((*strings)[3].safeGet<String>(), "gamma");
    EXPECT_EQ(assert_cast<const ColumnLowCardinality &>(*strings).getDictionary().size(), 4u); /// the default plus three keys

    ASSERT_EQ(numbers->size(), 4u);
    EXPECT_EQ((*numbers)[0].safeGet<UInt64>(), 7u);
    EXPECT_EQ((*numbers)[1].safeGet<UInt64>(), 8u);
    EXPECT_EQ((*numbers)[2].safeGet<UInt64>(), 9u);
    EXPECT_EQ((*numbers)[3].safeGet<UInt64>(), 10u);

    ASSERT_EQ(nullables->size(), 2u);
    EXPECT_EQ((*nullables)[0].safeGet<String>(), "gamma");
    EXPECT_TRUE((*nullables)[1].isNull());
}
