CREATE TABLE `operatorAuditEvents` (
	`id` varchar(36) NOT NULL,
	`ownerUserId` int NOT NULL,
	`action` varchar(96) NOT NULL,
	`resourceType` varchar(64) NOT NULL,
	`resourceId` varchar(128),
	`outcome` enum('success','blocked','failure') NOT NULL,
	`traceId` varchar(36),
	`detailJson` text NOT NULL,
	`createdAtMs` bigint NOT NULL,
	CONSTRAINT `operatorAuditEvents_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `operatorEvidenceArtifacts` (
	`id` varchar(64) NOT NULL,
	`ownerUserId` int NOT NULL,
	`traceId` varchar(36) NOT NULL,
	`name` varchar(240) NOT NULL,
	`kind` varchar(80) NOT NULL,
	`sizeBytes` bigint NOT NULL,
	`sha256` varchar(64) NOT NULL,
	`computedSha256` varchar(64),
	`mediaType` varchar(128) NOT NULL,
	`storageKey` varchar(512),
	`verified` boolean NOT NULL DEFAULT false,
	`verificationError` text,
	`sanitized` boolean NOT NULL DEFAULT false,
	`createdAtMs` bigint NOT NULL,
	`verifiedAtMs` bigint,
	CONSTRAINT `operatorEvidenceArtifacts_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `operatorJobs` (
	`id` varchar(36) NOT NULL,
	`ownerUserId` int NOT NULL,
	`agentJobId` varchar(64),
	`scenario` enum('canary','launch','tabs','browser','media','diagnostics','recovery','hardware','all') NOT NULL,
	`deviceUdid` varchar(40) NOT NULL,
	`idempotencyKey` varchar(64) NOT NULL,
	`retryCount` int NOT NULL,
	`attempt` int NOT NULL DEFAULT 0,
	`status` enum('queued','preparing','running','cancelling','succeeded','failed','cancelled','timed_out') NOT NULL,
	`phase` varchar(96) NOT NULL,
	`traceId` varchar(36),
	`errorCode` varchar(96),
	`errorMessage` text,
	`createdAtMs` bigint NOT NULL,
	`startedAtMs` bigint,
	`finishedAtMs` bigint,
	`updatedAtMs` bigint NOT NULL,
	CONSTRAINT `operatorJobs_id` PRIMARY KEY(`id`),
	CONSTRAINT `operatorJobs_idempotency_idx` UNIQUE(`idempotencyKey`)
);
--> statement-breakpoint
CREATE TABLE `operatorLiveSessions` (
	`id` varchar(64) NOT NULL,
	`ownerUserId` int NOT NULL,
	`deviceUdid` varchar(40) NOT NULL,
	`state` enum('idle','starting','active','recovering','closing','closed','failed') NOT NULL,
	`bidiConnected` boolean NOT NULL DEFAULT false,
	`appiumSessionId` varchar(128),
	`sessionTraceId` varchar(36) NOT NULL,
	`traceparent` varchar(55) NOT NULL,
	`startedAtMs` bigint NOT NULL,
	`expiresAtMs` bigint NOT NULL,
	`lastHeartbeatAtMs` bigint NOT NULL,
	`closedAtMs` bigint,
	`updatedAtMs` bigint NOT NULL,
	CONSTRAINT `operatorLiveSessions_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `operatorPolicySnapshots` (
	`id` varchar(36) NOT NULL,
	`ownerUserId` int NOT NULL,
	`gateState` enum('open','blocked','unavailable') NOT NULL,
	`repository` varchar(200) NOT NULL,
	`repositoryPrivate` boolean NOT NULL,
	`summary` text NOT NULL,
	`failedChecksJson` text NOT NULL,
	`checksJson` text NOT NULL,
	`checkedAtMs` bigint NOT NULL,
	`createdAtMs` bigint NOT NULL,
	CONSTRAINT `operatorPolicySnapshots_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `operatorQuarantineEvents` (
	`id` varchar(36) NOT NULL,
	`ownerUserId` int NOT NULL,
	`action` enum('set','clear') NOT NULL,
	`mode` enum('manual','runner-maintenance','device-maintenance'),
	`reason` text,
	`deviceUdid` varchar(40),
	`acknowledgementMatched` boolean NOT NULL DEFAULT false,
	`agentConfirmed` boolean NOT NULL DEFAULT false,
	`createdAtMs` bigint NOT NULL,
	CONSTRAINT `operatorQuarantineEvents_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE INDEX `operatorAuditEvents_created_idx` ON `operatorAuditEvents` (`createdAtMs`);--> statement-breakpoint
CREATE INDEX `operatorAuditEvents_resource_idx` ON `operatorAuditEvents` (`resourceType`,`resourceId`);--> statement-breakpoint
CREATE INDEX `operatorAuditEvents_trace_idx` ON `operatorAuditEvents` (`traceId`);--> statement-breakpoint
CREATE INDEX `operatorEvidenceArtifacts_trace_created_idx` ON `operatorEvidenceArtifacts` (`traceId`,`createdAtMs`);--> statement-breakpoint
CREATE INDEX `operatorEvidenceArtifacts_verified_idx` ON `operatorEvidenceArtifacts` (`verified`,`createdAtMs`);--> statement-breakpoint
CREATE INDEX `operatorJobs_owner_updated_idx` ON `operatorJobs` (`ownerUserId`,`updatedAtMs`);--> statement-breakpoint
CREATE INDEX `operatorJobs_status_updated_idx` ON `operatorJobs` (`status`,`updatedAtMs`);--> statement-breakpoint
CREATE INDEX `operatorJobs_trace_idx` ON `operatorJobs` (`traceId`);--> statement-breakpoint
CREATE INDEX `operatorLiveSessions_owner_updated_idx` ON `operatorLiveSessions` (`ownerUserId`,`updatedAtMs`);--> statement-breakpoint
CREATE INDEX `operatorLiveSessions_state_updated_idx` ON `operatorLiveSessions` (`state`,`updatedAtMs`);--> statement-breakpoint
CREATE INDEX `operatorLiveSessions_trace_idx` ON `operatorLiveSessions` (`sessionTraceId`);--> statement-breakpoint
CREATE INDEX `operatorPolicySnapshots_checked_idx` ON `operatorPolicySnapshots` (`checkedAtMs`);--> statement-breakpoint
CREATE INDEX `operatorQuarantineEvents_created_idx` ON `operatorQuarantineEvents` (`createdAtMs`);