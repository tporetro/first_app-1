class BusinessLeadersController < ApplicationController
  # GET /business_leaders
  def index
    @leaders = if params[:q].present?
                 BusinessLeader.search(params[:q])
               else
                 BusinessLeader.all
               end
  end

  # GET /business_leaders/:id
  def show
    @leader = BusinessLeader.find(params[:id])
    return render :not_found unless @leader

    @connections     = @leader.connections
    @current_company = @leader.current_company
    @board_seats     = @leader.board_seats
    @work_history    = @leader.work_history
  end

  # GET /business_leaders/:id/network
  # Returns the extended network up to N hops for B2B targeting
  def network
    @leader = BusinessLeader.find(params[:id])
    return render :not_found unless @leader

    hops = (params[:hops] || 2).to_i.clamp(1, 3)
    @network_leaders = @leader.network_within(hops)
    @hops = hops
  end

  # GET /business_leaders/:id/path?target_id=…
  # Introduction chain: who can introduce me to the target leader?
  def path
    @leader = BusinessLeader.find(params[:id])
    return render :not_found unless @leader

    @target = BusinessLeader.find(params[:target_id])
    return render :not_found unless @target

    @path    = @leader.introduction_path_to(@target.id)
    @degrees = @path.length - 1
  end

  # GET /business_leaders/:id/mutual?other_id=…
  def mutual
    @leader = BusinessLeader.find(params[:id])
    return render :not_found unless @leader

    @other   = BusinessLeader.find(params[:other_id])
    return render :not_found unless @other

    @mutual = @leader.mutual_connections_with(@other.id)
  end
end
