'use strict';

var aws = require('aws-sdk');

const region = 'us-east-2';

const dynamoClient = () => {
  aws.config.update({ region });
  const config = {
    region,
    maxRetries: 10,
    endpoint: `https://dynamodb.${region}.amazonaws.com`
  };

  const db = new aws.DynamoDB.DocumentClient(config);

  const put = (...args) => db.put(...args)
    .promise()
    .catch((err) => {
      return Promise.reject(err);
    });

  return { put }
}

const db = dynamoClient();

const handler = (event, context, callback) => {
  const nowUtc = () => new Date(new Date().toUTCString().substr(0, 25));
  /* For the sake of this test, I'm only saving one record;
     in reality, we could receive n-number of records from SQS. */
  if(event && event.Records && event.Records.length > 0) {
    const record = event.Records[0];
    const data = JSON.parse(record.body);
    const messageId = record.messageId;
    if(data && data.body) {
      const document = {
        messageId,
        createdAt: nowUtc().toISOString(),
        record: JSON.stringify(data.body)
      };
      return db.put({
        TableName: 'fakecompany',
        Item: document,
        ReturnValues: 'ALL_OLD'
      }).catch(err => {
        const errDocument = { err, document };
        const dlq = new aws.SQS({ region });
        const dlqParams = {
          MessageBody: JSON.stringify(errDocument),
          QueueUrl: `https://sqs.${region}.amazonaws.com/${process.env.ACCOUNT_NUMBER}/fakecompany-data-dlq`
        };
        const send = dlq.sendMessage(dlqParams).promise();
        return send;
      });
    }
  }
};

module.exports = { handler };
