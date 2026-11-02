# Path 4: look at what Debezium put on the topic (topic = <topic.prefix>.<schema>.<table> = cdc.public.beer_sales).
docker compose -f docker/compose.yml -f docker/compose.kafka.yml exec kafka \
  /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:19092 --topic cdc.public.beer_sales \
  --from-beginning --max-messages 3
# An event: {"before":null,"after":{...row...},"source":{"lsn":...},"op":"c","ts_ms":...}   op: c=create u=update d=delete r=snapshot read
