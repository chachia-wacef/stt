{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "HeadInputObject",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::__BUCKET__/*"
    },
    {
      "Sid": "ListBucketForHeadObject404",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::__BUCKET__"
    }
  ]
}
