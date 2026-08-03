require 'csv'

# Implements the matching logic from docs/campaigns/rgv-mcallen/reference-job-matching-spec.md (Section 2):
# nearest eligible active job within radius R, or no match.
class ReferenceJobMatcher
  EARTH_RADIUS_MILES = 3958.8
  DEFAULT_RADIUS_MILES = 1.0
  DEFAULT_JOBS_CSV = File.expand_path('../data/rgv_mcallen_active_jobs.csv', __dir__)

  Job = Struct.new(:job_id, :reference_street, :city, :latitude, :longitude, keyword_init: true)

  def initialize(jobs_csv_path = DEFAULT_JOBS_CSV)
    @jobs = load_jobs(jobs_csv_path)
  end

  # Returns the nearest eligible Job within radius_miles of (lat, lng), or nil if none match.
  def match(lat:, lng:, radius_miles: DEFAULT_RADIUS_MILES)
    @jobs
      .map { |job| [job, haversine_distance_miles(lat, lng, job.latitude, job.longitude)] }
      .select { |_job, distance| distance <= radius_miles }
      .min_by { |_job, distance| distance }
      &.first
  end

  private

  def load_jobs(path)
    CSV.read(path, headers: true).filter_map do |row|
      next unless row['pipeline_ready'].to_s.strip.casecmp('true').zero?
      next unless %w[active scheduled].include?(row['job_status'].to_s.strip)
      next unless row['insurance_funded'].to_s.strip.casecmp('yes').zero?
      next unless row['client_consented'].to_s.strip.casecmp('yes').zero?

      Job.new(
        job_id: row['job_id'],
        reference_street: row['reference_street'],
        city: row['city'],
        latitude: Float(row['latitude']),
        longitude: Float(row['longitude'])
      )
    end
  end

  def haversine_distance_miles(lat1, lng1, lat2, lng2)
    rad = Math::PI / 180
    lat1_rad, lat2_rad = lat1 * rad, lat2 * rad
    dlat = (lat2 - lat1) * rad
    dlng = (lng2 - lng1) * rad

    a = Math.sin(dlat / 2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlng / 2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    EARTH_RADIUS_MILES * c
  end
end
