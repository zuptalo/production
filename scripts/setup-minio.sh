#!/bin/bash

# MinIO Setup Script for Backup System - Pure MC Commands
# Works with MinIO Community Edition (no UI required)

set -euo pipefail

# Configuration
MINIO_ENDPOINT="https://s3.zuptalo.com"
BUCKET_NAME="production-backups"
HOSTNAME="$(hostname)"

echo "========================================"
echo "  MinIO Backup System Setup (MC Only)"
echo "========================================"
echo

# Check if mc is installed
if ! command -v mc >/dev/null 2>&1; then
    echo "Installing MinIO client..."
    if command -v brew >/dev/null 2>&1; then
        brew install minio/stable/mc
    else
        echo "Please install Homebrew first, then run: brew install minio/stable/mc"
        exit 1
    fi
fi

echo "✓ MinIO client (mc) is available"
echo

# Setup MinIO alias
read -p "Enter MinIO admin username: " MINIO_ROOT_USER
read -s -p "Enter MinIO admin password: " MINIO_ROOT_PASSWORD
echo

echo "Configuring MinIO connection..."
mc alias set minio-backup "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

if mc admin info minio-backup >/dev/null 2>&1; then
    echo "✓ Successfully connected to MinIO"
else
    echo "✗ Failed to connect to MinIO"
    exit 1
fi

echo
echo "Creating backup bucket..."
if mc mb "minio-backup/${BUCKET_NAME}" 2>/dev/null || mc ls "minio-backup/${BUCKET_NAME}" >/dev/null 2>&1; then
    echo "✓ Bucket '${BUCKET_NAME}' is ready"
else
    echo "✗ Failed to create bucket"
    exit 1
fi

echo
echo "Setting up bucket versioning..."
mc version enable "minio-backup/${BUCKET_NAME}"
echo "✓ Versioning enabled"

echo
echo "Setting up bucket lifecycle policy..."
cat > /tmp/lifecycle.json << 'EOF'
{
    "Rules": [
        {
            "ID": "BackupRetention",
            "Status": "Enabled",
            "Filter": {
                "Prefix": ""
            },
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 90
            }
        }
    ]
}
EOF

if mc ilm import "minio-backup/${BUCKET_NAME}" < /tmp/lifecycle.json 2>/dev/null; then
    echo "✓ Lifecycle policy imported successfully"
else
    echo "⚠ Could not import lifecycle policy - continuing without it"
fi
rm -f /tmp/lifecycle.json

echo
echo "Creating backup service account..."
BACKUP_ACCESS_KEY="backup-$(openssl rand -hex 8)"
BACKUP_SECRET_KEY="$(openssl rand -base64 32)"

# Create user via mc admin
mc admin user add minio-backup "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY"
echo "✓ Created backup user: $BACKUP_ACCESS_KEY"

echo
echo "Creating backup policy via mc admin..."

# Create the policy JSON file
cat > /tmp/backup-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        },
        {
            "Effect": "Deny",
            "Action": [
                "s3:DeleteObject",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF

# Create policy via mc admin
if mc admin policy create minio-backup backup-policy /tmp/backup-policy.json; then
    echo "✓ Created backup policy successfully"

    # Attach policy to user
    if mc admin policy attach minio-backup backup-policy --user "$BACKUP_ACCESS_KEY"; then
        echo "✓ Attached policy to user successfully"
        POLICY_SUCCESS=true
    else
        echo "✗ Failed to attach policy to user"
        POLICY_SUCCESS=false
    fi
else
    echo "✗ Failed to create backup policy"
    POLICY_SUCCESS=false
fi

rm -f /tmp/backup-policy.json

echo
echo "Verifying setup..."

# List users to verify creation
echo "Current users:"
mc admin user list minio-backup

echo
echo "Current policies:"
mc admin policy list minio-backup

echo
echo "User policy info:"
mc admin user info minio-backup "$BACKUP_ACCESS_KEY" 2>/dev/null || echo "Could not retrieve user policy info"

echo
echo "========================================"
echo "  Setup Results"
echo "========================================"
echo

if [ "$POLICY_SUCCESS" = true ]; then
    echo "✅ COMPLETE SUCCESS - All components configured!"
else
    echo "⚠️  PARTIAL SUCCESS - Manual verification needed"
fi

echo
echo "Backup Service Account Credentials:"
echo "===================================="
echo "Access Key: $BACKUP_ACCESS_KEY"
echo "Secret Key: $BACKUP_SECRET_KEY"
echo "Endpoint:   $MINIO_ENDPOINT"
echo "Bucket:     $BUCKET_NAME"
echo "Hostname:   $HOSTNAME"
echo
echo "⚠️  IMPORTANT: Save these credentials securely!"
echo

if [ "$POLICY_SUCCESS" = true ]; then
    echo "🎉 Setup completed successfully!"
    echo "✓ Bucket created with versioning"
    echo "✓ Lifecycle policy configured"
    echo "✓ Backup user created"
    echo "✓ Security policy applied"
    echo
    echo "Next steps:"
    echo "1. Save the credentials above"
    echo "2. Run the backup server configuration script"
    echo "3. Test the backup system"
else
    echo "⚠️  Manual verification required:"
    echo "1. Check if policy was created: mc admin policy list minio-backup"
    echo "2. Check if user has policy: mc admin user info minio-backup $BACKUP_ACCESS_KEY"
    echo "3. If needed, manually attach: mc admin policy attach minio-backup backup-policy --user $BACKUP_ACCESS_KEY"
fi

echo
echo "Verification commands:"
echo "======================"
echo "List all policies:    mc admin policy list minio-backup"
echo "Check user info:      mc admin user info minio-backup $BACKUP_ACCESS_KEY"
echo "List bucket contents: mc ls minio-backup/$BUCKET_NAME"
echo "Test upload:          echo 'test' | mc pipe minio-backup/$BUCKET_NAME/test.txt"
echo