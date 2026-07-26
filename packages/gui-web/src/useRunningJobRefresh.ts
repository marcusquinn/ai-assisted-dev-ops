import { type Dispatch, type SetStateAction, useEffect } from "react";

type JobState<Job> = Record<string, Job>;
type RefreshJob<Job> = (
  jobId: string,
  setJobs: Dispatch<SetStateAction<JobState<Job>>>,
) => Promise<void>;

export function useRunningJobRefresh<Job>(
  runningJobIdsKey: string,
  refreshJob: RefreshJob<Job>,
  setJobs: Dispatch<SetStateAction<JobState<Job>>>,
): void {
  useEffect(() => {
    const runningJobIds = runningJobIdsKey.split("|").filter(Boolean);
    if (runningJobIds.length === 0) {
      return undefined;
    }

    const refreshRunningJobs = () => {
      for (const jobId of runningJobIds) {
        void refreshJob(jobId, setJobs);
      }
    };
    refreshRunningJobs();
    const timer = window.setInterval(refreshRunningJobs, 1_500);

    return () => window.clearInterval(timer);
  }, [refreshJob, runningJobIdsKey, setJobs]);
}
