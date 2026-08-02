CREATE TABLE `operatorEvidenceBundles` (
	`traceId` varchar(36) NOT NULL,
	`ownerUserId` int NOT NULL,
	`status` varchar(32) NOT NULL,
	`reasonsJson` text NOT NULL,
	`archiveSizeBytes` bigint NOT NULL,
	`archiveSha256` varchar(64) NOT NULL,
	`manifestSha256` varchar(64) NOT NULL,
	`totalCount` int NOT NULL,
	`verifiedCount` int NOT NULL,
	`rejectedCount` int NOT NULL,
	`sanitizedCount` int NOT NULL,
	`createdAtMs` bigint NOT NULL,
	`verifiedAtMs` bigint NOT NULL,
	CONSTRAINT `operatorEvidenceBundles_traceId` PRIMARY KEY(`traceId`)
);
--> statement-breakpoint
ALTER TABLE `operatorLiveSessions` ADD `leaseCiphertext` text;--> statement-breakpoint
CREATE INDEX `operatorEvidenceBundles_owner_verified_idx` ON `operatorEvidenceBundles` (`ownerUserId`,`verifiedAtMs`);