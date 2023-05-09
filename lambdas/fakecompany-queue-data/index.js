'use strict';

const aws = require('aws-sdk');

const region = 'us-east-2'

const authorize = (headers) => {
  const unauthorized = {
    errorType: "Unauthorized",
    httpStatus: 401
  };

  /* In the real world, this would authenticate :) */
  return !headers || headers['x-auth-token'] !== 'my-very-secret-token'
    ? Promise.reject(unauthorized)
    : Promise.resolve()
    ;
}

const handler = (event, context, callback) => {
  console.log(JSON.stringify(event));
  return authorize(event.headers)
    .then(() => {
      const sqs = new aws.SQS({ region });
      const sqsParams = {
        MessageBody: JSON.stringify(event),
        QueueUrl: `https://sqs.${region}.amazonaws.com/${process.env.ACCOUNT_NUMBER}/fakecompany-data`
      };

      const send = sqs.sendMessage(sqsParams).promise();
      return send.then(item => {
        return {
          isBase64Encoded: false,
          body: JSON.stringify({ ...item, body: event.body }),
          statusCode: "202",
          headers: {}
        }
      });
    }).catch(err => {
      const error = {
        errorType: err.errorType || "InternalServerError",
        httpStatus: err.httpStatus || 500,
        requestId: context.awsRequestId,
      };
      return {
        isBase64Encoded: false,
        statusCode: error.httpStatus,
        headers: { },
        body: JSON.stringify(error)
      };
    });
};

module.exports = { handler };
