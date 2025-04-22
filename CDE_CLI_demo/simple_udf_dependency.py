from demo_utils import simple_udf 
from pyspark.sql import SparkSession

if __name__ == '__main__':
  spark = SparkSession.builder.appName("Python UDF simple example").getOrCreate() 
  spark.udf.register("TSTAMP_TO_STRING", simple_udf.tstampToString)
  spark.sql("SELECT TSTAMP_TO_STRING(timestamp) AS tstamp_str, timestamp FROM factory.experimental_motors_enriched LIMIT 10").show()
