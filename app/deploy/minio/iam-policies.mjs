// Explicitly scoped policies, not a complete future web/media runtime policy.
export function policies(env = {}) {
  const names = ['ORIGINALS','VIDEO','PREVIEWS','POSTERS','AVATARS'].map(kind => {
    const value = env[`MINIO_BUCKET_${kind}`] ?? `anime-${kind.toLowerCase()}`;
    if (!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(value)) throw new Error('Invalid bucket name');
    return value;
  });
  if (new Set(names).size !== 5) throw new Error('Bucket names must differ');
  const arn = name => `arn:aws:s3:::${name}`;
  const policy = (actions, resources) => ({Version:'2012-10-17', Statement:[{Effect:'Allow', Action:actions, Resource:resources}]});
  return {
    provision: policy(['s3:CreateBucket','s3:ListBucket','s3:GetBucketVersioning',
      's3:GetBucketPolicy','s3:PutBucketPolicy','s3:DeleteBucketPolicy',
      's3:GetLifecycleConfiguration','s3:PutLifecycleConfiguration'], names.map(arn)),
    reader: policy(['s3:GetObject'], [names[1],names[2]].map(name => `${arn(name)}/*`)),
    uploader: policy(['s3:PutObject','s3:AbortMultipartUpload','s3:ListMultipartUploadParts'], [`${arn(names[0])}/*`])
  };
}
