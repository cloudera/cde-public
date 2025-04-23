from pyspark.sql import SparkSession

spark = SparkSession\
    .builder\
    .appName("MakeCLIDemoTable")\
    .getOrCreate()

spark.sql('CREATE DATABASE IF NOT EXISTS factory')
spark.sparkContext.parallelize([
                      (12946, 1581040418), \
                      (12901, 1591040418), \
                      (90210, 1601040418), \
                      (63119, 1611040418), \
                      (10001, 1621040418)])\
        .map(lambda x: (x[0], x[1])).toDF(['zip','timestamp'])\
        .write\
        .mode("overwrite")\
        .saveAsTable('factory.experimental_motors_enriched')

spark.stop()
